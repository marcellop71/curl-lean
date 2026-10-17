// WebSocket connection management
// This file implements proper persistent WebSocket connections using libcurl

#include <lean/lean.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <poll.h>
#include <time.h>

// Global connection storage
#define MAX_CONNECTIONS 1024
static CURL* g_connections[MAX_CONNECTIONS] = {0};
static uint32_t g_next_handle = 1;

// Initialize curl globals (called once)
static int g_curl_initialized = 0;
static void ensure_global_init_ws() {
  if (!g_curl_initialized) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    g_curl_initialized = 1;
  }
}

// Parse headers from "Header: value\nHeader: value" format
static struct curl_slist* parse_headers_ws(const char* headers_str) {
  if (!headers_str || strlen(headers_str) == 0) return NULL;
  
  struct curl_slist* headers = NULL;
  char* headers_copy = strdup(headers_str);
  char* line = strtok(headers_copy, "\n");
  
  while (line) {
    // Skip empty lines
    if (strlen(line) > 0) {
      headers = curl_slist_append(headers, line);
    }
    line = strtok(NULL, "\n");
  }
  
  free(headers_copy);
  return headers;
}

// Find next available connection slot
static uint32_t allocate_connection_handle() {
  for (int i = 0; i < MAX_CONNECTIONS; i++) {
    if (g_connections[i] == NULL) {
      return i + 1; // Handle 0 is reserved for "invalid"
    }
  }
  return 0; // No free slots
}

// WebSocket connect - establishes persistent connection
// Returns IO (UInt32 × String): handle (0 on error), response or error message
lean_obj_res lean_curl_ws_connect(
  b_lean_obj_arg urlObj,
  b_lean_obj_arg headersObj,
  uint32_t timeout_ms,
  uint8_t verify_ssl,
  uint8_t verbose,
  lean_obj_arg w
) {
  ensure_global_init_ws();

  const char* url = lean_string_cstr(urlObj);
  const char* headers = lean_string_cstr(headersObj);

  CURL* curl = curl_easy_init();
  if (!curl) {
    lean_object* handle = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("curl_easy_init failed");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, handle);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  // Configure WebSocket connection
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 2L); // WebSocket upgrade

  // SSL configuration
  if (verify_ssl == 0) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
  } else {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  }

  if (verbose != 0) {
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
  }

  if (timeout_ms > 0) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  }

  struct curl_slist* hdrs = parse_headers_ws(headers);
  if (hdrs) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
  }

  // Establish WebSocket connection
  CURLcode rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    const char* emsg = curl_easy_strerror(rc);
    lean_object* handle = lean_box_uint32(0);
    lean_object* msg = lean_mk_string(emsg);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, handle);
    lean_ctor_set(pair, 1, msg);
    if (hdrs) curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    return lean_io_result_mk_ok(pair);
  }

  // Connection successful - store it and return handle
  uint32_t handle = allocate_connection_handle();
  if (handle == 0) {
    lean_object* handle_obj = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Maximum connections exceeded");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, handle_obj);
    lean_ctor_set(pair, 1, msg);
    if (hdrs) curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    return lean_io_result_mk_ok(pair);
  }

  g_connections[handle - 1] = curl;
  
  lean_object* handle_obj = lean_box_uint32(handle);
  lean_object* msg = lean_mk_string("WebSocket connection established");
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, handle_obj);
  lean_ctor_set(pair, 1, msg);

  if (hdrs) curl_slist_free_all(hdrs);
  return lean_io_result_mk_ok(pair);
}

// WebSocket send on existing connection
// Returns IO (UInt32 × String): status (0 on error, 1 on success), response or error message
lean_obj_res lean_curl_ws_send_on_connection(
  uint32_t handle,
  b_lean_obj_arg messageObj,
  uint8_t is_binary,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL) {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Invalid connection handle");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];
  const char* message = lean_string_cstr(messageObj);

  size_t sent;
  int flags = is_binary ? CURLWS_BINARY : CURLWS_TEXT;
  CURLcode rc = curl_ws_send(curl, message, strlen(message), &sent, 0, flags);
  
  if (rc != CURLE_OK) {
    const char* emsg = curl_easy_strerror(rc);
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string(emsg);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  lean_object* status = lean_box_uint32(1);
  lean_object* msg = lean_mk_string("Message sent successfully");
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, status);
  lean_ctor_set(pair, 1, msg);
  return lean_io_result_mk_ok(pair);
}

// WebSocket send frame with specific type on existing connection
// Returns IO (UInt32 × String): status (0 on error, 1 on success), response or error message
lean_obj_res lean_curl_ws_send_frame_on_connection(
  uint32_t handle,
  b_lean_obj_arg messageObj,
  uint32_t frame_flags,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL) {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Invalid connection handle");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];
  const char* message = lean_string_cstr(messageObj);

  size_t sent;
  // Map frame_flags to libcurl WebSocket flags
  int flags = 0;
  if (frame_flags & 1) flags |= CURLWS_TEXT;
  if (frame_flags & 2) flags |= CURLWS_BINARY;
  if (frame_flags & 4) flags |= CURLWS_PING;
  if (frame_flags & 8) flags |= CURLWS_PONG;
  if (frame_flags & 16) flags |= CURLWS_CLOSE;
  if (frame_flags == 0) flags |= CURLWS_CONT;  // continuation frame
  
  CURLcode rc = curl_ws_send(curl, message, strlen(message), &sent, 0, flags);
  
  if (rc != CURLE_OK) {
    const char* emsg = curl_easy_strerror(rc);
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string(emsg);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  lean_object* status = lean_box_uint32(1);
  lean_object* msg = lean_mk_string("Frame sent successfully");
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, status);
  lean_ctor_set(pair, 1, msg);
  return lean_io_result_mk_ok(pair);
}

// ---------------------------------------------------------------------------
// WebSocket receive
//
// curl_ws_recv hands back whatever part of a frame is available: a frame larger than
// the buffer, or one whose bytes have not all arrived yet, comes back in pieces
// (meta->bytesleft > 0), and a fragmented message comes as several frames
// (CURLWS_CONT on all but the last). recv_message assembles one complete message and,
// when no data is available, waits on the socket with poll() instead of returning
// at once, so callers neither split messages nor sleep-and-retry.
// ---------------------------------------------------------------------------

#define WS_RECV_CHUNK 65536
#define WS_MAX_MESSAGE (64u * 1024u * 1024u)
#define WS_MID_MESSAGE_TIMEOUT_MS 10000  // once a message has started, wait this long for the rest

static int64_t ws_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Wait up to timeout_ms for the connection's socket to become readable.
// Returns 1 readable, 0 timeout, -1 error.
static int ws_wait_readable(CURL* curl, int64_t timeout_ms) {
  curl_socket_t sock = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(curl, CURLINFO_ACTIVESOCKET, &sock) != CURLE_OK || sock == CURL_SOCKET_BAD)
    return -1;
  if (timeout_ms < 0) timeout_ms = 0;
  struct pollfd pfd = { .fd = sock, .events = POLLIN, .revents = 0 };
  int rc;
  do {
    rc = poll(&pfd, 1, (int)timeout_ms);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) return -1;
  return rc > 0 ? 1 : 0;
}

static lean_obj_res ws_recv_result(uint32_t frame_type, const char* data, size_t len) {
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, lean_box_uint32(frame_type));
  lean_ctor_set(pair, 1, lean_mk_string_from_bytes(data, len));
  return lean_io_result_mk_ok(pair);
}

static lean_obj_res ws_recv_error(const char* msg) {
  return ws_recv_result(0, msg, strlen(msg));
}

static uint32_t ws_frame_type(int flags) {
  if (flags & CURLWS_CLOSE) return 3;
  if (flags & CURLWS_PING) return 4;
  if (flags & CURLWS_PONG) return 5;
  if (flags & CURLWS_BINARY) return 2;
  return 1;  // text
}

// Receive one complete message, waiting up to timeout_ms for it to start
// (0 = only what is already available). Returns (frameType, data); frameType 0 with a
// "RETRY:" message when nothing arrived in time, or with "ERROR:" on failure.
// Frame types: 1 text, 2 binary, 3 close, 4 ping, 5 pong.
static lean_obj_res ws_recv_message(uint32_t handle, uint32_t timeout_ms) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL)
    return ws_recv_error("ERROR: Invalid connection handle");
  CURL* curl = g_connections[handle - 1];

  const int64_t start_deadline = ws_now_ms() + timeout_ms;
  int64_t mid_deadline = 0;
  char* buf = NULL;
  size_t len = 0, cap = 0;
  int started = 0;
  uint32_t type = 1;
  char err[512];

  for (;;) {
    if (cap - len < WS_RECV_CHUNK) {
      size_t ncap = cap ? cap * 2 : WS_RECV_CHUNK * 2;
      char* nbuf = (char*)realloc(buf, ncap);
      if (!nbuf) { free(buf); return ws_recv_error("ERROR: Failed to allocate receive buffer"); }
      buf = nbuf; cap = ncap;
    }
    size_t n = 0;
    const struct curl_ws_frame* meta = NULL;
    CURLcode rc = curl_ws_recv(curl, buf + len, cap - len, &n, &meta);

    if (rc == CURLE_AGAIN) {
      int64_t deadline = started ? mid_deadline : start_deadline;
      int64_t left = deadline - ws_now_ms();
      if (left <= 0) {
        free(buf);
        if (started) return ws_recv_error("ERROR: Timed out in the middle of a message");
        return ws_recv_error("RETRY: Socket not ready for receive (CURLE_AGAIN). Try again later.");
      }
      if (ws_wait_readable(curl, left) < 0) {
        free(buf);
        return ws_recv_error("ERROR: Waiting for the WebSocket socket failed");
      }
      continue;
    }
    if (rc != CURLE_OK) {
      free(buf);
      snprintf(err, sizeof(err), "ERROR: curl_ws_recv failed: %s (code: %d)", curl_easy_strerror(rc), rc);
      return ws_recv_error(err);
    }
    if (meta == NULL) {
      free(buf);
      return ws_recv_error("ERROR: No frame info received");
    }

    int is_control = meta->flags & (CURLWS_CLOSE | CURLWS_PING | CURLWS_PONG);
    if (started && is_control && type != ws_frame_type(meta->flags)) {
      // A control frame between the fragments of a data message (RFC 6455 §5.4).
      // Control frames are at most 125 bytes, so this read holds all of it; drop it
      // unless it is a close.
      if (meta->flags & CURLWS_CLOSE) {
        lean_obj_res r = ws_recv_result(3, buf + len, n);
        free(buf);
        return r;
      }
      continue;
    }
    if (!started) {
      started = 1;
      type = ws_frame_type(meta->flags);
      mid_deadline = ws_now_ms() + WS_MID_MESSAGE_TIMEOUT_MS;
    }
    len += n;
    if (len > WS_MAX_MESSAGE) {
      free(buf);
      return ws_recv_error("ERROR: WebSocket message too large");
    }
    if (meta->bytesleft == 0 && !(meta->flags & CURLWS_CONT)) {
      lean_obj_res r = ws_recv_result(type, buf, len);
      free(buf);
      return r;
    }
  }
}

// Receive one complete message, waiting up to timeout_ms for it to start
// Returns IO (UInt32 × String): frame type (0=retry/error, 1=text, 2=binary, 3=close, 4=ping, 5=pong), data
lean_obj_res lean_curl_ws_recv_message(uint32_t handle, uint32_t timeout_ms, lean_obj_arg w) {
  return ws_recv_message(handle, timeout_ms);
}

// WebSocket receive on existing connection: one complete message if available
// (no waiting). Returns IO (UInt32 × String) as lean_curl_ws_recv_message.
lean_obj_res lean_curl_ws_recv_on_connection(uint32_t handle, lean_obj_arg w) {
  return ws_recv_message(handle, 0);
}

// Kept for compatibility: messages are no longer limited by a buffer size
lean_obj_res lean_curl_ws_recv_on_connection_with_buffer(uint32_t handle, uint32_t buffer_size, lean_obj_arg w) {
  (void)buffer_size;
  return ws_recv_message(handle, 0);
}

// WebSocket close connection
// Returns IO (UInt32 × String): status (0 on error, 1 on success), response or error message
lean_obj_res lean_curl_ws_close_connection(
  uint32_t handle,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL) {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Invalid connection handle");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];
  curl_easy_cleanup(curl);
  g_connections[handle - 1] = NULL;

  lean_object* status = lean_box_uint32(1);
  lean_object* msg = lean_mk_string("Connection closed");
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, status);
  lean_ctor_set(pair, 1, msg);
  return lean_io_result_mk_ok(pair);
}

// Check if WebSocket connection is still valid
// Returns IO (UInt32 × String): status (0 = invalid, 1 = valid), status message
lean_obj_res lean_curl_ws_check_connection(
  uint32_t handle,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS) {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Invalid handle value");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  if (g_connections[handle - 1] == NULL) {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Connection handle not found or closed");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];
  
  // Try to get connection info to verify it's still valid
  char* effective_url = NULL;
  CURLcode rc = curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);
  
  if (rc == CURLE_OK && effective_url != NULL) {
    lean_object* status = lean_box_uint32(1);
    char msg_buffer[256];
    snprintf(msg_buffer, sizeof(msg_buffer), "Connection valid for URL: %s", effective_url);
    lean_object* msg = lean_mk_string(msg_buffer);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  } else {
    lean_object* status = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("Connection appears to be invalid or closed");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, status);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }
}
