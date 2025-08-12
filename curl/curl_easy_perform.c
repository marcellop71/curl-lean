// Returns IO (UInt32 × String):
//   status code (0 on curl error), and response body (or error message on error).
lean_obj_res lean_curl_easy_perform(
  b_lean_obj_arg methodObj,
  b_lean_obj_arg urlObj,
  b_lean_obj_arg bodyObj,
  b_lean_obj_arg headersObj,
  b_lean_obj_arg userAgentObj, // User-Agent string (empty string to use default)
  uint32_t timeout_ms,
  uint8_t verify_ssl,     // 1 = verify SSL certificates, 0 = skip verification
  uint8_t verbose,        // 1 = enable verbose debug output, 0 = disable
  lean_obj_arg w
) {
  ensure_global_init();

  const char* method  = lean_string_cstr(methodObj);
  const char* url     = lean_string_cstr(urlObj);
  const char* body    = lean_string_cstr(bodyObj);
  const char* headers = lean_string_cstr(headersObj);
  const char* userAgent = lean_string_cstr(userAgentObj);

  CURL* curl = curl_easy_init();
  buffer_t buf = {0};
  long status = 0;

  if (!curl) {
    lean_object* st = lean_box_uint32(0);
    lean_object* s  = lean_mk_string("curl_easy_init failed");
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, st);
    lean_ctor_set(pair, 1, s);
    return lean_io_result_mk_ok(pair);
  }

  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, ""); // enable compression
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
  curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 2L);
  curl_easy_setopt(curl, CURLOPT_BUFFERSIZE, 2048L); // 16 KB buffer
  curl_easy_setopt(curl, CURLOPT_TCP_NODELAY, 1L); // disable Nagle's algorithm
  curl_easy_setopt(curl, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 0L);

  // User-Agent configuration
  if (userAgent && userAgent[0]) {
    curl_easy_setopt(curl, CURLOPT_USERAGENT, userAgent);
  }
  // If userAgent is empty or null, curl will use its default User-Agent

  // HTTPS/SSL configuration
  if (verify_ssl == 0) {
    // Disable SSL certificate verification (insecure mode)
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
  } else {
    // Enable SSL certificate verification (default/secure mode)
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  }

  // Verbose debug configuration
  if (verbose != 0) {
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
  }

  if (timeout_ms > 0) {
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
  }

  struct curl_slist* hdrs = parse_headers(headers);
  if (hdrs) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);

  if (ieq(method, "POST")) {
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
  } else if (!ieq(method, "GET")) {
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    if (body && body[0]) {
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
    }
  }

  CURLcode rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    const char* emsg = curl_easy_strerror(rc);
    lean_object* st = lean_box_uint32(0);
    lean_object* s  = lean_mk_string(emsg);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, st);
    lean_ctor_set(pair, 1, s);
    if (hdrs) curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    free(buf.data);
    return lean_io_result_mk_ok(pair);
  }

  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

  lean_object* st = lean_box_uint32((uint32_t)status);
  lean_object* s  = lean_mk_string(buf.data ? buf.data : "");
  lean_object* pair = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(pair, 0, st);
  lean_ctor_set(pair, 1, s);

  if (hdrs) curl_slist_free_all(hdrs);
  curl_easy_cleanup(curl);
  free(buf.data);

  return lean_io_result_mk_ok(pair);
}
