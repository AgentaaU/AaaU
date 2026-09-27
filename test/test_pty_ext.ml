(* Coverage-oriented tests for the PTY helpers that do not require root. *)

open AaaU

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let current_user () = (Unix.getpwuid (Unix.geteuid ())).Unix.pw_name

let with_pty f =
  match Pty.open_pty () with
  | Error message -> fail "open_pty failed: %s" message
  | Ok (pty, slave) ->
    Fun.protect
      ~finally:(fun () -> Lwt_main.run (Pty.close pty))
      (fun () -> f pty slave)

let test_sizes () =
  with_pty (fun _pty slave ->
    let fd = Unix.openfile (slave :> string) [ Unix.O_RDWR; Unix.O_NOCTTY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Pty.set_terminal_size fd ~rows:40 ~cols:120;
        let rows, cols = Pty.get_terminal_size fd in
        expect (rows = 40 && cols = 120)
          (Printf.sprintf "unexpected size %dx%d" rows cols);
        (* Invalid sizes are ignored rather than wrapping through ioctl. *)
        Pty.set_terminal_size fd ~rows:0 ~cols:(-1);
        let rows, cols = Pty.get_terminal_size fd in
        expect (rows = 40 && cols = 120) "invalid size changed the terminal";
        Pty.set_terminal_size fd ~rows:1001 ~cols:1001;
        Pty.set_raw_mode fd))

let test_size_fallbacks () =
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () -> Unix.close read_fd; Unix.close write_fd)
    (fun () ->
      (* A pipe is not a terminal, so the ioctl must fall back cleanly. *)
      let rows, cols = Pty.get_terminal_size read_fd in
      expect (rows = 24 && cols = 80)
        (Printf.sprintf "unexpected fallback size %dx%d" rows cols);
      Pty.set_terminal_size read_fd ~rows:10 ~cols:10)

let test_controlling_terminal () =
  with_pty (fun _pty slave ->
    let fd = Unix.openfile (slave :> string) [ Unix.O_RDWR ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () -> Pty.set_controlling_terminal fd))

let test_configure_slave () =
  with_pty (fun _pty slave ->
    let fd = Unix.openfile (slave :> string) [ Unix.O_RDWR; Unix.O_NOCTTY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () -> Pty.configure_slave fd));
  (* A non-terminal makes tcgetattr fail; the helper swallows the error. *)
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () -> Unix.close read_fd; Unix.close write_fd)
    (fun () -> Pty.configure_slave read_fd)

let test_login_shell_argv () =
  let argv = Pty.login_shell_argv ~program:"/bin/echo" ~args:[ "a"; "b" ] in
  expect (Array.length argv = 9) "unexpected argv length";
  expect (argv.(0) = "/bin/bash") "shell missing";
  expect (argv.(6) = "/bin/echo") "program position changed";
  expect (argv.(7) = "a" && argv.(8) = "b") "argument order changed"

let test_fork_errors () =
  with_pty (fun _pty slave ->
    (match
       Pty.fork_agent ~slave ~user:(current_user ())
         ~program:"/nonexistent/aaau-program" ~args:[] ~env:[] ~rows:24 ~cols:80
     with
    | Error message ->
      expect
        (String.starts_with ~prefix:"Program not found" message)
        (Printf.sprintf "unexpected missing-program error: %s" message)
    | Ok pid ->
      ignore (Unix.waitpid [] pid);
      fail "missing program was forked");

    let path = Filename.temp_file "aaau-nonexec-" ".sh" in
    Fun.protect
      ~finally:(fun () -> Unix.unlink path)
      (fun () ->
        (match
           Pty.fork_agent ~slave ~user:(current_user ()) ~program:path ~args:[]
             ~env:[] ~rows:24 ~cols:80
         with
        | Error message ->
          expect
            (String.starts_with ~prefix:"Program not executable" message)
            (Printf.sprintf "unexpected non-executable error: %s" message)
        | Ok pid ->
          ignore (Unix.waitpid [] pid);
          fail "non-executable program was forked")))

let test_fork_success () =
  with_pty (fun _pty slave ->
    (match
       Pty.fork_agent ~slave ~user:(current_user ()) ~program:"/bin/true"
         ~args:[] ~env:[ ("AAAU_TEST", "1") ] ~rows:30 ~cols:90
     with
    | Error message -> fail "fork_agent failed: %s" message
    | Ok pid ->
      let _, status = Unix.waitpid [] pid in
      expect (status = Unix.WEXITED 0)
        (Printf.sprintf "unexpected child status: %s"
           (match status with
            | Unix.WEXITED n -> string_of_int n
            | Unix.WSIGNALED n -> "signal " ^ string_of_int n
            | Unix.WSTOPPED n -> "stop " ^ string_of_int n)));

    (* A non-absolute command is resolved by the login shell. *)
    (match
       Pty.fork_agent ~slave ~user:(current_user ()) ~program:"true" ~args:[]
         ~env:[] ~rows:24 ~cols:80
     with
    | Error message -> fail "PATH command failed: %s" message
    | Ok pid ->
      let _, status = Unix.waitpid [] pid in
      expect (status = Unix.WEXITED 0) "PATH command exited non-zero");

    (* A missing account fails inside the child and exits with status 1. *)
    match
      Pty.fork_agent ~slave ~user:"aaau-no-such-account" ~program:"/bin/true"
        ~args:[] ~env:[] ~rows:24 ~cols:80
    with
    | Error _ -> ()
    | Ok pid ->
      let _, status = Unix.waitpid [] pid in
      expect (status = Unix.WEXITED 1) "missing account did not fail cleanly")

let test_slave_path () =
  with_pty (fun pty slave ->
    expect (String.starts_with ~prefix:"/dev/pts/" (Pty.get_slave_path pty :> string))
      "slave path is not a pts device";
    expect ((Pty.get_slave_path pty :> string) = (slave :> string))
      "slave path mismatch";
    ignore (Pty.fd pty))

let () =
  test_sizes ();
  test_size_fallbacks ();
  test_controlling_terminal ();
  test_configure_slave ();
  test_login_shell_argv ();
  test_fork_errors ();
  test_fork_success ();
  test_slave_path ();
  print_endline "pty tests passed"
