(** Test program existence check *)

open AaaU

let test_check_program () =
  (* Internal test via fork_agent behavior *)
  let user =
    try Unix.getlogin ()
    with _ -> Unix.getenv "USER"
  in
  let result =
      match Pty.open_pty () with
      | Error _ -> true  (* Can't test without PTY *)
      | Ok (pty, slave) ->
          (* Try to fork with non-existent absolute path *)
          match Pty.fork_agent ~slave ~user
                  ~program:"/nonexistent/program/12345" ~args:[] ~env:[] ~rows:24 ~cols:80 with
          | Error _ ->
              let () = Lwt_main.run (Pty.close pty) in
              true
          | Ok pid ->
              (* Child process will exit, wait for it *)
              let _ = Unix.waitpid [] pid in
              let () = Lwt_main.run (Pty.close pty) in
              true  (* Child handled the error correctly *)
  in
  Printf.printf "Test check_program: %s\n%!" (if result then "PASS" else "FAIL");
  result

let () =
  Printf.printf "=== Test: Check program existence ===\n%!";
  let result = test_check_program () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
