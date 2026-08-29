#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static const char *checked_path(value path) {
  const char *result = String_val(path);
  if (strlen(result) != caml_string_length(path)) caml_invalid_argument("editor path contains NUL");
  return result;
}

CAMLprim value aaau_open_nofollow_rw(value path) {
  CAMLparam1(path);
  int fd = open(checked_path(path), O_RDWR | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) uerror("open editor buffer", path);
  CAMLreturn(Val_int(fd));
}

CAMLprim value aaau_open_nofollow_ro(value path) {
  CAMLparam1(path);
  int fd = open(checked_path(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) uerror("open editor temporary", path);
  CAMLreturn(Val_int(fd));
}

CAMLprim value aaau_create_exclusive(value path, value mode) {
  CAMLparam2(path, mode);
  int fd = open(checked_path(path), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                Int_val(mode));
  if (fd == -1) uerror("create editor temporary", path);
  CAMLreturn(Val_int(fd));
}
