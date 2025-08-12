// c/curl_shim.c
#include <lean/lean.h>
#include <curl/curl.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
  char *data;
  size_t size;
} buffer_t;

// WebSocket frame data structure
typedef struct {
  char *data;
  size_t size;
  int is_binary;
  int is_final;
} ws_frame_t;

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  size_t total = size * nmemb;
  buffer_t *buf = (buffer_t*)userdata;
  char *p = (char*)realloc(buf->data, buf->size + total + 1);
  if (!p) return 0; // OOM -> libcurl will treat as error
  buf->data = p;
  memcpy(buf->data + buf->size, ptr, total);
  buf->size += total;
  buf->data[buf->size] = 0;
  return total;
}

static struct curl_slist* parse_headers(const char* headers) {
  struct curl_slist* list = NULL;
  if (!headers || !headers[0]) return NULL;
  const char* start = headers;
  const char* p = headers;
  while (*p) {
    if (*p == '\r') { p++; continue; }  // ignore CR
    if (*p == '\n') {
      size_t len = p - start;
      if (len > 0) {
        char* line = (char*)malloc(len + 1);
        if (line) {
          memcpy(line, start, len);
          line[len] = 0;
          list = curl_slist_append(list, line);
          free(line);
        }
      }
      start = p + 1;
    }
    p++;
  }
  if (p > start) {
    size_t len = p - start;
    if (len > 0) {
      char* line = (char*)malloc(len + 1);
      if (line) {
        memcpy(line, start, len);
        line[len] = 0;
        list = curl_slist_append(list, line);
        free(line);
      }
    }
  }
  return list;
}

static int ieq(const char* a, const char* b) {
#if defined(_WIN32)
  return _stricmp(a, b) == 0;
#else
  return strcasecmp(a, b) == 0;
#endif
}

static void ensure_global_init(void) {
  static int inited = 0;
  if (!inited) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    atexit(curl_global_cleanup);
    inited = 1;
  }
}

// WebSocket write callback for receiving frames
static size_t ws_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  size_t total = size * nmemb;
  buffer_t *buf = (buffer_t*)userdata;
  char *p = (char*)realloc(buf->data, buf->size + total + 1);
  if (!p) return 0; // OOM -> libcurl will treat as error
  buf->data = p;
  memcpy(buf->data + buf->size, ptr, total);
  buf->size += total;
  buf->data[buf->size] = 0;
  return total;
}

#include "curl_easy_perform.c"
#include "curl_ws_connect.c"
