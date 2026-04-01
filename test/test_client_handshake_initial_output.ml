(** Test the client handshake path when buffered output arrives in the same
    socket read as the SESSION line. *)

open Lwt.Syntax

let test_client_handshake_initial_output () =
  let client_fd, server_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let payload = "SESSION:test-session\nhello from history\n" in

  let result =
    Lwt_main.run (
      let writer =
        let* () = AaaU.Client_io.write_all server_fd payload in
        Lwt_unix.close server_fd
      in
      let reader = AaaU.Client_io.read_handshake_response ~timeout:0.5 client_fd in
      let* handshake_result = Lwt.both writer reader |> Lwt.map snd in
      let* () = Lwt_unix.close client_fd in
      Lwt.return handshake_result
    )
  in

  match result with
  | AaaU.Client_io.Timeout ->
    Printf.printf "FAIL: timed out waiting for handshake response\n%!";
    false
  | AaaU.Client_io.Response (handshake_line, initial_output) ->
    if handshake_line <> "SESSION:test-session" then begin
      Printf.printf "FAIL: unexpected handshake line: %S\n%!" handshake_line;
      false
    end else if initial_output <> "hello from history\n" then begin
      Printf.printf "FAIL: unexpected trailing output: %S\n%!" initial_output;
      false
    end else begin
      Printf.printf "PASS: handshake and buffered output were split correctly\n%!";
      true
    end

let () =
  Printf.printf "=== Test: Client handshake with buffered output ===\n%!";
  let result = test_client_handshake_initial_output () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
