static pthread_once_t ar_curl_once = PTHREAD_ONCE_INIT;
static CURLcode ar_curl_init_status;
static void ar_curl_init(void) { ar_curl_init_status = curl_global_init(CURL_GLOBAL_DEFAULT); }
static size_t ar_response(char *data, size_t size, size_t n, void *arg) {
  ARBuffer *out = arg;
  if (!size || n > ((1 << 20) - out->len)/size) return 0;
  ar_append(out, data, n*size);
  return n*size;
}
static void ar_http(void *task) {
  ARWork *w = task;
  const char *url = w->arg[0], *key = w->arg[1], *body = w->arg[2];
  if ((strncmp(url, "http://", 7) && strncmp(url, "https://", 8)) || strpbrk(key, "\r\n")) {
    ar_message(w, "invalid HTTP endpoint or API key"); return;
  }
  pthread_once(&ar_curl_once, ar_curl_init);
  CURL *curl = ar_curl_init_status ? NULL : curl_easy_init();
  if (!curl) { ar_message(w, "cannot initialize HTTP"); return; }
  ARBuffer response = {0};
  struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
  char *authorization = NULL;
  if (*key) {
    if (asprintf(&authorization, "Authorization: Bearer %s", key) < 0) abort();
    headers = curl_slist_append(headers, authorization);
  }
  curl_easy_setopt(curl, CURLOPT_URL, url);
#if LIBCURL_VERSION_NUM >= 0x075500
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
#else
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#endif
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, ar_response);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
  if (*body) curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
  CURLcode error = curl_easy_perform(curl);
  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
  if (error) ar_message(w, curl_easy_strerror(error));
  else {
    char code[16];
    snprintf(code, sizeof code, "%ld", status);
    ar_field(&w->out, code);
    if (response.len) ar_append(&w->out, response.data, response.len);
  }
  curl_easy_cleanup(curl);
  curl_slist_free_all(headers);
  free(authorization); free(response.data);
}
static pthread_mutex_t ar_spawn_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool ar_capture(ARWork *w, char *const args[], ARBuffer *out, size_t limit) {
  int pipefd[2];
  pthread_mutex_lock(&ar_spawn_mutex);
  if (pipe(pipefd) != 0) {
    ar_error(w, args[0], errno);
    pthread_mutex_unlock(&ar_spawn_mutex);
    return false;
  }
  fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
  fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
  posix_spawn_file_actions_t actions;
  int status = posix_spawn_file_actions_init(&actions);
  bool initialized = status == 0;
  if (!status) status = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
  if (!status) status = posix_spawn_file_actions_adddup2(&actions, pipefd[1], 1);
  if (!status) status = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
  pid_t pid;
  extern char **environ;
  if (!status) status = posix_spawnp(&pid, args[0], &actions, NULL, args, environ);
  if (initialized) posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);
  pthread_mutex_unlock(&ar_spawn_mutex);
  if (status) { close(pipefd[0]); ar_error(w, args[0], status); return false; }
  uint64_t until = io_tick() + 120000000000ULL;
  bool ok = true;
  for (;;) {
    struct pollfd p = {.fd=pipefd[0], .events=POLLIN};
    uint64_t now = io_tick();
    int delay = now < until ? (int)((until-now)/1000000) : 0;
    int ready = poll(&p, 1, delay);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) { ok = false; break; }
    char chunk[8192];
    ssize_t n = read(pipefd[0], chunk, sizeof chunk);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) { ok = false; break; }
    if (!n) break;
    size_t accepted = (size_t)n > limit - out->len ? limit - out->len : (size_t)n;
    if (accepted) ar_append(out, chunk, accepted);
  }
  close(pipefd[0]);
  if (!ok) kill(pid, SIGKILL);
  for (;;) {
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result < 0 && errno == EINTR) continue;
    if (result == pid) break;
    if (result < 0) { ok = false; break; }
    if (io_tick() >= until) { ok = false; kill(pid, SIGKILL); }
    struct timespec interval = {0, 10000000};
    nanosleep(&interval, NULL);
  }
  if (!ok || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    char message[160];
    snprintf(message, sizeof message, "%s failed or timed out", args[0]);
    ar_message(w, message);
    return false;
  }
  return true;
}
static const char ar_b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void ar_base64(ARBuffer *out, const unsigned char *bytes, size_t len) {
  size_t chars = 4*((len+2)/3);
  if (out->len + chars + 1 > out->cap) {
    out->cap = out->len + chars + 1;
    out->data = io_mem(realloc(out->data, out->cap));
  }
  for (size_t i = 0; i < len; i += 3) {
    unsigned a = bytes[i], b = i+1<len ? bytes[i+1] : 0, c = i+2<len ? bytes[i+2] : 0;
    char quad[] = {ar_b64[a>>2], ar_b64[((a&3)<<4)|(b>>4)], i+1<len ? ar_b64[((b&15)<<2)|(c>>6)] : '=',
      i+2<len ? ar_b64[c&63] : '='};
    memcpy(out->data + out->len, quad, 4);
    out->len += 4;
  }
  out->data[out->len] = 0;
}
static bool ar_image(ARWork *w, const char *path) {
  const char *ext = ar_ext(path), *mime = "image/jpeg";
  if (!strcasecmp(ext, ".png")) mime = "image/png";
  if (!strcasecmp(ext, ".tif") || !strcasecmp(ext, ".tiff")) mime = "image/tiff";
  if (!strcasecmp(ext, ".bmp")) mime = "image/bmp";
  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) { ar_error(w, "open image", errno); return false; }
  struct stat st;
  ARBuffer image = {0};
  bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && ar_read(fd, &image, (20<<20)+1);
  close(fd);
  if (!ok || !image.len || image.len > 20<<20 || w->out.len + image.len * 2 > 64<<20) {
    ar_message(w, "unreadable image or image size limit exceeded"); free(image.data); return false;
  }
  ar_field(&w->out, mime);
  ar_base64(&w->out, (const unsigned char *)image.data, image.len);
  ar_append(&w->out, "", 1);
  free(image.data);
  return true;
}
static void ar_video(ARWork *w, char *path, int frames) {
  ARBuffer out = {0};
  char *probe[] = {"ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
    "default=noprint_wrappers=1:nokey=1", path, NULL};
  bool ok = ar_capture(w, probe, &out, 2048);
  double seconds = out.len ? strtod(out.data, NULL) : 0;
  free(out.data); out = (ARBuffer){0};
  if (!ok) return;
  if (!isfinite(seconds) || seconds <= 0) { ar_message(w, "video has no positive duration"); return; }
  int count = seconds < frames ? (int)seconds : frames;
  if (count < 1) count = 1;
  const char *tmp = getenv("TMPDIR");
  if (!tmp || !*tmp) tmp = "/tmp";
  char *dir = ar_join(tmp, "ai-renamer-XXXXXX");
  if (!mkdtemp(dir)) { ar_error(w, "create frame directory", errno); free(dir); return; }
  char *pattern = ar_join(dir, "frame_%03d.jpg");
  char rate[64], number[12];
  snprintf(rate, sizeof rate, "fps=%g", count/seconds);
  snprintf(number, sizeof number, "%d", count);
  char *command[] = {"ffmpeg", "-nostdin", "-v", "error", "-threads", "1", "-filter_threads", "1",
    "-i", path, "-vf", rate, "-frames:v", number, "-q:v", "2", "-threads", "1", pattern, NULL};
  ok = ar_capture(w, command, &out, 8192);
  char *paths[64] = {0};
  size_t found = 0;
  for (int i = 1; i <= count; ++i) {
    char name[32];
    snprintf(name, sizeof name, "frame_%03d.jpg", i);
    char *item = ar_join(dir, name);
    if (access(item, F_OK) == 0) paths[found++] = item;
    else free(item);
  }
  if (ok && found) {
    char prompt[192];
    snprintf(prompt, sizeof prompt, "Analyze these %zu frames from a %.1f-second video. One frame every %.1f seconds.",
      found, seconds, seconds/count);
    ar_field(&w->out, prompt);
    for (size_t i = 0; i < found && !w->error; ++i) ar_image(w, paths[i]);
  } else if (ok) ar_message(w, "no video frames could be extracted");
  for (size_t i = 0; i < found; ++i) { unlink(paths[i]); free(paths[i]); }
  rmdir(dir);
  free(pattern); free(dir); free(out.data);
}
static void ar_material(void *task) {
  ARWork *w = task;
  char *kind = w->arg[0], *path = w->arg[2];
  if (!strcmp(kind, "image")) { ar_field(&w->out, ""); ar_image(w, path); return; }
  if (!strcmp(kind, "video")) {
    int frames = atoi(w->arg[1]);
    if (frames < 1 || frames > 64) { ar_message(w, "invalid frame count"); return; }
    ar_video(w, path, frames); return;
  }
  if (!strcmp(kind, "pdf")) {
    char *args[] = {"pdftotext", path, "-", NULL};
    ar_capture(w, args, &w->out, 1 << 20);
    return;
  }
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) { ar_error(w, "open input file", errno); return; }
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || !ar_read(fd, &w->out, 1 << 20))
    ar_message(w, "cannot read input file");
  close(fd);
}

