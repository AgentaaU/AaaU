(* Coverage-oriented tests for the client-side socket helpers. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let with_socketpair f =
  let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Lwt.finalize
    (fun () -> f left right)
    (fun () ->
      let* () = Lwt.catch (fun () -> Lwt_unix.close left) (fun _ -> Lwt.return_unit) in
      Lwt.catch (fun () -> Lwt_unix.close right) (fun _ -> Lwt.return_unit))

let run f = Lwt_main.run (with_socketpair f)

let test_split_handshake_response () =
  let line, rest = AaaU.Client_io.split_handshake_response "SESSION:abc\nhello" in
  expect (line = "SESSION:abc") "line not split";
  expect (rest = "hello") "trailing bytes not preserved";
  let line, rest = AaaU.Client_io.split_handshake_response " just-a-line " in
  expect (line = "just-a-line") "unterminated line not trimmed";
  expect (rest = "") "unterminated line produced trailing bytes";
  let line, rest = AaaU.Client_io.split_handshake_response "line\n" in
  expect (line = "line" && rest = "") "empty remainder not handled"

let test_write_all () =
  run (fun reader writer ->
      let* () = AaaU.Client_io.write_all writer "" in
      let payload = String.make 70000 'w' in
      let writer_task = AaaU.Client_io.write_all writer payload in
      let rec read_all acc remaining =
        if remaining = 0 then Lwt.return acc
        else
          let buffer = Bytes.create 8192 in
          let* count = Lwt_unix.read reader buffer 0 (min 8192 remaining) in
          if count = 0 then Lwt.return acc
          else read_all (acc ^ Bytes.sub_string buffer 0 count) (remaining - count)
      in
      let reader_task = read_all "" (String.length payload) in
      let* (), received = Lwt.both writer_task reader_task in
      expect (received = payload) "write_all did not send every byte";
      Lwt.return_unit)

let test_read_line () =
  run (fun reader writer ->
      let* () = AaaU.Client_io.write_all writer "hello\nrest" in
      let* result = AaaU.Client_io.read_line_with_remainder ~timeout:1.0 reader in
      match result with
      | AaaU.Client_io.Line (line, rest) ->
        expect (line = "hello") "line mismatch";
        expect (rest = "rest") "remainder mismatch";
        Lwt.return_unit
      | _ -> fail "expected a line");

  run (fun reader writer ->
      let* () = Lwt_unix.close writer in
      let* result = AaaU.Client_io.read_line_with_remainder ~timeout:1.0 reader in
      match result with
      | AaaU.Client_io.End_of_file -> Lwt.return_unit
      | _ -> fail "clean EOF was not reported");

  run (fun reader writer ->
      let* () = AaaU.Client_io.write_all writer "partial" in
      let* () = Lwt_unix.close writer in
      let* result = AaaU.Client_io.read_line_with_remainder ~timeout:1.0 reader in
      match result with
      | AaaU.Client_io.Line ("partial", "") -> Lwt.return_unit
      | _ -> fail "partial final line was not returned");

  run (fun reader _writer ->
      let* result = AaaU.Client_io.read_line_with_remainder ~timeout:0.05 reader in
      match result with
      | AaaU.Client_io.Timeout_line -> Lwt.return_unit
      | _ -> fail "timeout was not reported");

  run (fun reader writer ->
      let* () = AaaU.Client_io.write_all writer "abcdef\n" in
      Lwt.catch
        (fun () ->
          let* _ = AaaU.Client_io.read_line_with_remainder ~max_length:4 ~timeout:1.0 reader in
          fail "oversized line was accepted")
        (fun _ -> Lwt.return_unit))

let test_read_handshake_response () =
  run (fun reader writer ->
      let* () = AaaU.Client_io.write_all writer "SESSION:abc\nhello" in
      let* result = AaaU.Client_io.read_handshake_response ~timeout:1.0 reader in
      match result with
      | AaaU.Client_io.Response ("SESSION:abc", "hello") -> Lwt.return_unit
      | _ -> fail "handshake response mismatch");

  run (fun reader writer ->
      let* () = Lwt_unix.close writer in
      let* result = AaaU.Client_io.read_handshake_response ~timeout:1.0 reader in
      match result with
      | AaaU.Client_io.Response ("", "") -> Lwt.return_unit
      | _ -> fail "empty handshake response mismatch");

  run (fun reader _writer ->
      let* result = AaaU.Client_io.read_handshake_response ~timeout:0.05 reader in
      match result with
      | AaaU.Client_io.Timeout -> Lwt.return_unit
      | _ -> fail "handshake timeout was not reported")

let () =
  test_split_handshake_response ();
  test_write_all ();
  test_read_line ();
  test_read_handshake_response ();
  print_endline "client io tests passed"
