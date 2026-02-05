// WebSocket connection management
// This file implements proper persistent WebSocket connections using libcurl

#include <lean/lean.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

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

// WebSocket receive on existing connection
// Returns IO (UInt32 × String): frame type (0=error, 1=text, 2=binary, 3=close, 4=ping, 5=pong, 6=continuation), message data
lean_obj_res lean_curl_ws_recv_on_connection(
  uint32_t handle,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL) {
    lean_object* frame_type = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("ERROR: Invalid connection handle");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];

  // Receive WebSocket frame
  char buffer[4096];
  size_t recv_bytes;
  const struct curl_ws_frame *frame_info;
  
  CURLcode rc = curl_ws_recv(curl, buffer, sizeof(buffer), &recv_bytes, &frame_info);
  
  if (rc != CURLE_OK) {
    char error_msg[512];
    if (rc == CURLE_AGAIN) {
      // Special handling for "socket not ready" - this is often recoverable
      snprintf(error_msg, sizeof(error_msg), "RETRY: Socket not ready for receive (CURLE_AGAIN). Try again later.");
    } else {
      snprintf(error_msg, sizeof(error_msg), "ERROR: curl_ws_recv failed: %s (code: %d)", curl_easy_strerror(rc), rc);
    }
    lean_object* frame_type = lean_box_uint32(0);
    lean_object* msg = lean_mk_string(error_msg);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  // Check if frame_info is valid
  if (frame_info == NULL) {
    lean_object* frame_type = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("ERROR: No frame info received");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  // Determine frame type - check in priority order
  uint32_t frame_type;
  if (frame_info->flags & CURLWS_CLOSE) {
    frame_type = 3; // Close frame
  } else if (frame_info->flags & CURLWS_PING) {
    frame_type = 4; // Ping frame
  } else if (frame_info->flags & CURLWS_PONG) {
    frame_type = 5; // Pong frame
  } else if (frame_info->flags & CURLWS_BINARY) {
    frame_type = 2; // Binary frame
  } else if (frame_info->flags & CURLWS_CONT) {
    frame_type = 6; // Continuation frame
  } else {
    frame_type = 1; // Text frame (default)
  }

  // Null-terminate the received data
  if (recv_bytes < sizeof(buffer)) {
    buffer[recv_bytes] = '\0';
  } else {
    buffer[sizeof(buffer) - 1] = '\0';
  }

  lean_object* frame_type_obj = lean_box_uint32(frame_type);
  lean_object* msg = lean_mk_string(buffer);
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, frame_type_obj);
  lean_ctor_set(pair, 1, msg);
  return lean_io_result_mk_ok(pair);
}

// WebSocket receive on existing connection with configurable buffer size
// Handles large messages by reading in a loop until the full frame is received
// Returns IO (UInt32 × String): frame type (0=error, 1=text, 2=binary, 3=close, 4=ping, 5=pong, 6=continuation), message data
lean_obj_res lean_curl_ws_recv_on_connection_with_buffer(
  uint32_t handle,
  uint32_t buffer_size,
  lean_obj_arg w
) {
  if (handle == 0 || handle > MAX_CONNECTIONS || g_connections[handle - 1] == NULL) {
    lean_object* frame_type = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("ERROR: Invalid connection handle");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  CURL* curl = g_connections[handle - 1];

  // Clamp buffer size to reasonable limits (min 1KB, max 1MB)
  if (buffer_size < 1024) buffer_size = 1024;
  if (buffer_size > 1048576) buffer_size = 1048576;

  // Allocate buffer dynamically
  char* buffer = (char*)malloc(buffer_size);
  if (!buffer) {
    lean_object* frame_type = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("ERROR: Failed to allocate receive buffer");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  // Receive WebSocket frame - read in loop to handle large messages
  size_t total_recv = 0;
  size_t recv_bytes;
  const struct curl_ws_frame *frame_info = NULL;
  uint32_t frame_type = 1; // Default to text

  while (total_recv < buffer_size - 1) {
    CURLcode rc = curl_ws_recv(curl, buffer + total_recv, buffer_size - total_recv - 1, &recv_bytes, &frame_info);

    if (rc == CURLE_AGAIN) {
      if (total_recv == 0) {
        // No data at all yet - signal retry
        free(buffer);
        lean_object* frame_type_obj = lean_box_uint32(0);
        lean_object* msg = lean_mk_string("RETRY: Socket not ready for receive (CURLE_AGAIN). Try again later.");
        lean_object* pair = lean_alloc_ctor(0, 2, 0);
        lean_ctor_set(pair, 0, frame_type_obj);
        lean_ctor_set(pair, 1, msg);
        return lean_io_result_mk_ok(pair);
      }
      // We have some data but socket would block - continue with what we have
      break;
    }

    if (rc != CURLE_OK) {
      char error_msg[512];
      snprintf(error_msg, sizeof(error_msg), "ERROR: curl_ws_recv failed: %s (code: %d)", curl_easy_strerror(rc), rc);
      free(buffer);
      lean_object* frame_type_obj = lean_box_uint32(0);
      lean_object* msg = lean_mk_string(error_msg);
      lean_object* pair = lean_alloc_ctor(0, 2, 0);
      lean_ctor_set(pair, 0, frame_type_obj);
      lean_ctor_set(pair, 1, msg);
      return lean_io_result_mk_ok(pair);
    }

    total_recv += recv_bytes;

    // Check frame_info for frame type (only on first chunk)
    if (frame_info != NULL && total_recv == recv_bytes) {
      if (frame_info->flags & CURLWS_CLOSE) {
        frame_type = 3;
      } else if (frame_info->flags & CURLWS_PING) {
        frame_type = 4;
      } else if (frame_info->flags & CURLWS_PONG) {
        frame_type = 5;
      } else if (frame_info->flags & CURLWS_BINARY) {
        frame_type = 2;
      } else if (frame_info->flags & CURLWS_CONT) {
        frame_type = 6;
      } else {
        frame_type = 1;
      }
    }

    // Check if we've received the complete frame
    if (frame_info != NULL && frame_info->bytesleft == 0) {
      break; // Complete frame received
    }

    // Safety check - if recv_bytes is 0, avoid infinite loop
    if (recv_bytes == 0) {
      break;
    }
  }

  // Handle case where no frame_info was received
  if (frame_info == NULL && total_recv == 0) {
    free(buffer);
    lean_object* frame_type_obj = lean_box_uint32(0);
    lean_object* msg = lean_mk_string("ERROR: No frame info received");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, frame_type_obj);
    lean_ctor_set(pair, 1, msg);
    return lean_io_result_mk_ok(pair);
  }

  // Null-terminate the received data
  buffer[total_recv] = '\0';

  lean_object* frame_type_obj = lean_box_uint32(frame_type);
  lean_object* msg = lean_mk_string(buffer);
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, frame_type_obj);
  lean_ctor_set(pair, 1, msg);

  free(buffer);
  return lean_io_result_mk_ok(pair);
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
