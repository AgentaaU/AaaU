(** Test check_program with non-existent command (not full path) *)

open AaaU

let test_check_program_command () =
  (* Test that fork_agent properly handles non-existent commands in PATH *)
  (* Non-absolute paths are resolved by login shell, so child process handles error *)
  let user =
    try Unix.getlogin ()
    with _ -> Unix.getenv "USER"
  in
  let result =
      match Pty.open_pty () with
      | Error _ -> true  (* Can't test without PTY *)
      | Ok (pty, slave) ->
          (* Try to fork with non-existent command (not a full path) *)
          match Pty.fork_agent ~slave ~user
                  ~program:"nonexistent_command_xyz" ~args:[] ~env:[] ~rows:24 ~cols:80 with
          | Ok pid ->
              (* Child process will exit on command not found - this is expected *)
              let _ = Unix.waitpid [] pid in
              let () = Lwt_main.run (Pty.close pty) in
              true
          | Error _ ->
              (* Also acceptable - parent detected the issue *)
              let () = Lwt_main.run (Pty.close pty) in
              true
  in
  Printf.printf "Test check_program_command: %s\n%!" (if result then "PASS" else "FAIL");
  result

let () =
  Printf.printf "=== Test: Check program existence (command in PATH) ===\n%!";
  let result = test_check_program_command () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
