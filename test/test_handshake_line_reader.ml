(** Tests for newline-terminated handshake I/O under fragmentation. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt

let with_socketpair f =
  let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Lwt.finalize
    (fun () -> f left right)
    (fun () ->
      let* () = Lwt.catch (fun () -> Lwt_unix.close left) (fun _ -> Lwt.return_unit) in
      Lwt.catch (fun () -> Lwt_unix.close right) (fun _ -> Lwt.return_unit))

let test_fragmented_line_read () =
  Lwt_main.run (
    with_socketpair (fun reader writer ->
      let writer_task =
        let* () = AaaU.Client_io.write_all writer "SESSION:" in
        let* () = Lwt_unix.sleep 0.05 in
        AaaU.Client_io.write_all writer "test-session\nframed-output"
      in
      let reader_task = AaaU.Client_io.read_line_with_remainder ~timeout:0.5 reader in
      let* result = Lwt.both writer_task reader_task |> Lwt.map snd in
      match result with
      | AaaU.Client_io.Line (line, remaining) ->
        if line <> "SESSION:test-session" then
          fail "unexpected line: %S" line;
        if remaining <> "framed-output" then
          fail "unexpected remainder: %S" remaining;
        Lwt.return_unit
      | AaaU.Client_io.Timeout_line ->
        fail "timed out waiting for fragmented line"
      | AaaU.Client_io.End_of_file ->
        fail "unexpected EOF"))

let test_large_line_read () =
  let large_args = String.make 2048 'x' in
  let payload = "NEW_JSON:{\"program\":\"/bin/echo\",\"args\":[\"" ^ large_args ^ "\"],\"rows\":24,\"cols\":80}\nrest" in
  Lwt_main.run (
    with_socketpair (fun reader writer ->
      let writer_task = AaaU.Client_io.write_all writer payload in
      let reader_task = AaaU.Client_io.read_line_with_remainder ~timeout:0.5 reader in
      let* result = Lwt.both writer_task reader_task |> Lwt.map snd in
      match result with
      | AaaU.Client_io.Line (line, remaining) ->
        if not (String.starts_with ~prefix:"NEW_JSON:" line) then
          fail "unexpected line prefix: %S" line;
        if remaining <> "rest" then
          fail "unexpected remainder after large line: %S" remaining;
        Lwt.return_unit
      | AaaU.Client_io.Timeout_line ->
        fail "timed out waiting for large line"
      | AaaU.Client_io.End_of_file ->
        fail "unexpected EOF"))

let () =
  Printf.printf "=== Test: Handshake line reader ===\n%!";
  test_fragmented_line_read ();
  Printf.printf "PASS: fragmented line read\n%!";
  test_large_line_read ();
  Printf.printf "PASS: large line read\n%!";
  Printf.printf "PASS\n%!"
