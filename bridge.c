/* Included in the C emitted by Bend. Go runs on Bend's IO helper threads. */
extern char *renamer_host(char *, char *, size_t, size_t *, int *);

typedef struct {
  char *op, *input, *output;
  size_t size, length;
  int failed;
} RenamerWork;

static void renamer_call(IoWork *w) {
  RenamerWork *task = (RenamerWork *)w->data;
  task->output = renamer_host(task->op, task->input, task->size, &task->length, &task->failed);
}

static Term renamer_pack(Env e, IoWork *w) {
  RenamerWork *task = (RenamerWork *)w->data;
  Term result = task->failed ? io_fail(e, EIO, task->output)
                            : io_done(e, io_str(e, task->output, task->length));
  free(task->op);
  free(task->input);
  free(task->output);
  free(task);
  return result;
}

static Term renamer_run(Env e, Term *f, IoWork *w) {
  RenamerWork *task = calloc(1, sizeof(*task));
  if (!task) return io_fail(e, ENOMEM, NULL);
  u64 op_length, input_length;
  task->op = io_cstr(e, f[0], &op_length);
  task->input = io_cstr(e, f[1], &input_length);
  task->size = (size_t)input_length;
  w->data = (char *)task;
  io_sync();
  return io_work(w, renamer_call, renamer_pack);
}

static void __attribute__((constructor)) renamer_use(void) {
  io_eff(CID(raw), renamer_run);
}
