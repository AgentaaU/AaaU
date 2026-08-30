(** Test that fork_agent creates PTY with correct terminal size
   Regression test for: opencode didn't occupy the entire window of terminal *)

open AaaU

let test_fork_agent_terminal_size () =
  let user = (Unix.getpwuid (Unix.geteuid ())).Unix.pw_name in
  match Pty.open_pty () with
    | Error msg ->
        Printf.printf "FAIL: Could not open PTY: %s\n%!" msg;
        false
    | Ok (pty, slave) ->
        (* Test with custom terminal size (not the default 24x80) *)
        let expected_rows = 50 in
        let expected_cols = 120 in

        (* Fork a simple command that exits immediately *)
        match Pty.fork_agent ~slave ~user
                ~program:"/bin/true" ~args:[] ~env:[]
                ~rows:expected_rows ~cols:expected_cols with
        | Error msg ->
            Printf.printf "FAIL: Could not fork agent: %s\n%!" msg;
            Lwt_main.run (Pty.close pty);
            false
        | Ok pid ->
            (* Wait for child to exit *)
            let _ = Unix.waitpid [] pid in

            (* Verify the terminal size was set by reading it from the PTY master *)
            (* Note: get_terminal_size on master should reflect the slave size after fork *)
            let (actual_rows, actual_cols) = Pty.get_terminal_size (Pty.fd pty) in

            let result =
              if actual_rows = expected_rows && actual_cols = expected_cols then begin
                Printf.printf "PASS: Terminal size correctly set to %dx%d (expected %dx%d)\n%!"
                  actual_rows actual_cols expected_rows expected_cols;
                true
              end else begin
                Printf.printf "FAIL: Terminal size mismatch: got %dx%d, expected %dx%d\n%!"
                  actual_rows actual_cols expected_rows expected_cols;
                false
              end
            in
            Lwt_main.run (Pty.close pty);
            result

let () =
  Printf.printf "=== Test: Fork agent with custom terminal size ===\n%!";
  let result = test_fork_agent_terminal_size () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
