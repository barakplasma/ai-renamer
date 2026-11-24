package main

/*
#include <stdlib.h>
int renamer_move_exclusive(int, const char *, const char *);
*/
import "C"

import (
	"fmt"
	"strings"
	"syscall"
	"unsafe"
)

func moveExclusive(dir uintptr, from, to string) error {
	a, b := C.CString(from), C.CString(to)
	defer C.free(unsafe.Pointer(a))
	defer C.free(unsafe.Pointer(b))
	if code := C.renamer_move_exclusive(C.int(dir), a, b); code != 0 {
		return syscall.Errno(code)
	}
	return nil
}

//export renamer_host
func renamer_host(op, input *C.char, n C.size_t, length *C.size_t, failed *C.int) *C.char {
	var args []string
	if n > 0 {
		args = strings.Split(C.GoStringN(input, C.int(n)), "\x00")
	}
	result, err := dispatch(C.GoString(op), args)
	if err != nil {
		result = err.Error()
		*failed = 1
	}
	*length = C.size_t(len(result))
	return C.CString(result)
}

func dispatch(op string, args []string) (string, error) {
	switch {
	case op == "config" && len(args)%2 == 0:
		return config(args)
	case op == "scan" && len(args) == 2:
		return scan(args[0], args[1] == "true")
	case op == "models" && len(args) == 3:
		return models(args[0], args[1], args[2])
	case op == "suggest" && len(args) == 9:
		return suggest(args)
	case op == "begin" && len(args) == 0:
		return beginRun()
	case op == "rename" && len(args) == 3:
		return renameFile(args[0], args[1], args[2])
	case op == "rollback" && len(args) == 2:
		return rollback(args[0], args[1])
	case op == "runs" && len(args) == 0:
		return listRuns()
	default:
		return "", fmt.Errorf("invalid host operation or argument count: %s", op)
	}
}

func main() {}
