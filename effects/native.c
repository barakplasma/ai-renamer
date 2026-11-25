/* Direct Bend effects. Included by the native C emitter. */
#include <curl/curl.h>
#include <dirent.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/sha.h>
#include <sys/random.h>
#endif

typedef struct { char *data; size_t len, cap; } ARBuffer;
typedef struct {
  char *arg[4]; ARBuffer out; char *error; void (*work)(void *);
} ARWork;
static void ar_append(ARBuffer *b, const void *data, size_t n) {
  if (b->len + n + 1 > b->cap) {
    b->cap = (b->len + n + 1) * 2;
    b->data = io_mem(realloc(b->data, b->cap));
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
  b->data[b->len] = 0;
}
static void ar_text(ARBuffer *b, const char *s) { ar_append(b, s, strlen(s)); }
static void ar_field(ARBuffer *b, const char *s) { ar_append(b, s, strlen(s) + 1); }
static void ar_error(ARWork *w, const char *context, int code) {
  if (!w->error && asprintf(&w->error, "%s: %s", context, strerror(code)) < 0) abort();
}
static void ar_message(ARWork *w, const char *message) {
  if (!w->error) w->error = io_mem(strdup(message));
}
static void ar_call(IoWork *w) {
  ARWork *x = (ARWork *)w->data;
  x->work(x);
}
static Term ar_pack(Env e, IoWork *w) {
  ARWork *x = (ARWork *)w->data;
  Term result = x->error ? io_fail(e, EIO, x->error)
                        : io_done(e, io_str(e, x->out.data ? x->out.data : "", x->out.len));
  for (int i = 0; i < 4; ++i) free(x->arg[i]);
  free(x->out.data);
  free(x->error);
  free(x);
  return result;
}
static Term ar_start(Env e, Term *f, IoWork *w, unsigned count, void (*work)(void *)) {
  ARWork *x = io_mem(calloc(1, sizeof(*x)));
  for (unsigned i = 0; i < count; ++i) {
    u64 length;
    x->arg[i] = io_cstr(e, f[i], &length);
    if (strlen(x->arg[i]) != length) ar_message(x, "NUL is not allowed in effect arguments");
  }
  x->work = work;
  w->data = (char *)x;
  io_sync();
  return x->error ? ar_pack(e, w) : io_work(w, ar_call, ar_pack);
}
static bool ar_write(int fd, const void *data, size_t n) {
  const char *p = data;
  while (n) {
    ssize_t used = write(fd, p, n);
    if (used < 0 && errno == EINTR) continue;
    if (used <= 0) return false;
    p += used; n -= (size_t)used;
  }
  return true;
}
static bool ar_read(int fd, ARBuffer *out, size_t limit) {
  char bytes[8192];
  while (out->len < limit) {
    size_t room = limit - out->len;
    ssize_t n = read(fd, bytes, room < sizeof bytes ? room : sizeof bytes);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return false;
    if (!n) break;
    ar_append(out, bytes, (size_t)n);
  }
  return true;
}
static char *ar_join(const char *dir, const char *name) {
  char *p;
  if (asprintf(&p, "%s%s%s", dir, *dir && dir[strlen(dir)-1] == '/' ? "" : "/", name) < 0) abort();
  return p;
}
static char *ar_parent(const char *path) {
  char *parent = io_mem(strdup(path));
  char *slash = strrchr(parent, '/');
  if (!slash) { free(parent); return io_mem(strdup(".")); }
  slash[slash == parent] = 0;
  return parent;
}
static const char *ar_name(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}
static const char *ar_ext(const char *name) {
  const char *ext = strrchr(name, '.');
  return ext && ext != name ? ext : name + strlen(name);
}
static bool ar_component(const char *s) {
  if (!*s || !strcmp(s, ".") || !strcmp(s, "..") || strpbrk(s, "/\\:*?\"<>|")) return false;
  for (; *s; ++s) if ((unsigned char)*s < 32) return false;
  return true;
}
static bool ar_syncdir(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return false;
  int result = fsync(fd), error = errno;
  close(fd); errno = error;
  return result == 0;
}
static bool ar_mkdirs(const char *path) {
  struct stat st;
  if (stat(path, &st) == 0) {
    if (S_ISDIR(st.st_mode)) return true;
    errno = ENOTDIR; return false;
  }
  if (errno != ENOENT) return false;
  char *parent = ar_parent(path);
  bool ok = ar_mkdirs(parent) && (mkdir(path, 0700) == 0 || errno == EEXIST) && ar_syncdir(parent);
  free(parent);
  return ok;
}
static char *ar_state_dir(void) {
  const char *base = getenv("XDG_STATE_HOME");
  if (base && *base) {
    if (*base != '/') { errno = EINVAL; return NULL; }
    return ar_join(base, "ai-renamer");
  }
  const char *home = getenv("HOME");
  if (!home || *home != '/') { errno = EINVAL; return NULL; }
  return ar_join(home, ".local/state/ai-renamer");
}
static int ar_mutations(const char *state) {
  char *path = ar_join(state, "mutations.lock");
  int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  free(path);
  if (fd >= 0 && flock(fd, LOCK_EX) != 0) {
    int code = errno; close(fd); errno = code; return -1;
  }
  return fd;
}
static int ar_exclusive(int fd, const char *src, const char *dst) {
#ifdef __APPLE__
  return renameatx_np(fd, src, fd, dst, RENAME_EXCL);
#else
  return renameat2(fd, src, fd, dst, RENAME_NOREPLACE);
#endif
}

#include "effects/files.h"
#include "effects/journal.h"
#include "effects/media.h"

#ifdef CID(load_config_native)
static Term ar_io_load_config(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 1, ar_load); }
static void __attribute__((constructor)) ar_use_load_config(void) { io_eff(CID(load_config_native), ar_io_load_config); }
#endif

#ifdef CID(save_config_native)
static Term ar_io_save_config(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 1, ar_save); }
static void __attribute__((constructor)) ar_use_save_config(void) { io_eff(CID(save_config_native), ar_io_save_config); }
#endif

#ifdef CID(scan_native)
static Term ar_io_scan(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 2, ar_scan); }
static void __attribute__((constructor)) ar_use_scan(void) { io_eff(CID(scan_native), ar_io_scan); }
#endif

#ifdef CID(begin_run_native)
static Term ar_io_begin_run(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 0, ar_begin); }
static void __attribute__((constructor)) ar_use_begin_run(void) { io_eff(CID(begin_run_native), ar_io_begin_run); }
#endif

#ifdef CID(rename_file_native)
static Term ar_io_rename_file(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 4, ar_rename); }
static void __attribute__((constructor)) ar_use_rename_file(void) { io_eff(CID(rename_file_native), ar_io_rename_file); }
#endif

#ifdef CID(rollback_native)
static Term ar_io_rollback(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 2, ar_rollback); }
static void __attribute__((constructor)) ar_use_rollback(void) { io_eff(CID(rollback_native), ar_io_rollback); }
#endif

#ifdef CID(runs_native)
static Term ar_io_runs(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 0, ar_runs); }
static void __attribute__((constructor)) ar_use_runs(void) { io_eff(CID(runs_native), ar_io_runs); }
#endif

#ifdef CID(http_native)
static Term ar_io_http(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 3, ar_http); }
static void __attribute__((constructor)) ar_use_http(void) { io_eff(CID(http_native), ar_io_http); }
#endif

#ifdef CID(material_native)
static Term ar_io_material(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 4, ar_material); }
static void __attribute__((constructor)) ar_use_material(void) { io_eff(CID(material_native), ar_io_material); }
#endif

#ifdef CID(docling_native)
static Term ar_io_docling(Env e, Term *f, IoWork *w) { return ar_start(e, f, w, 3, ar_docling); }
static void __attribute__((constructor)) ar_use_docling(void) { io_eff(CID(docling_native), ar_io_docling); }
#endif
