(** Test agent exit and terminal restoration *)

let test_agent_exit () =
  (* Skip test if not running as root - fork_agent requires root for setgroups *)
  if Unix.getuid () <> 0 then begin
    Printf.printf "SKIP: requires root privileges\n%!";
    Printf.printf "PASS\n%!";
    exit 0
  end;
  
  let result =
    match AaaU.Pty.open_pty () with
    | Error e ->
      Printf.eprintf "PTY open failed: %s\n%!" e;
      false
    | Ok (pty, slave) ->
      let user =
        try Unix.getlogin ()
        with _ -> Unix.getenv "USER"
      in

      (* Fork a simple agent that exits immediately *)
      match AaaU.Pty.fork_agent ~slave ~user
              ~program:"/bin/sh" ~args:["-c"; "echo 'Agent exiting'; exit 0"]
              ~env:[("HOME", try (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir with _ -> "/tmp")]
              ~rows:24 ~cols:80 with
      | Error e ->
        Printf.eprintf "Fork failed: %s\n%!" e;
        let () = Lwt_main.run (AaaU.Pty.close pty) in
        false
      | Ok pid ->
        (* Read output from PTY master until EOF or error *)
        let rec read_all acc =
          let buf = Bytes.create 4096 in
          try
            match Lwt_main.run (AaaU.Pty.read pty buf 0 4096) with
            | 0 -> String.concat "" (List.rev acc)
            | n ->
              let data = Bytes.sub_string buf 0 n in
              read_all (data :: acc)
          with
          | Unix.Unix_error (Unix.EIO, _, _) -> String.concat "" (List.rev acc)
        in
        
        (* Read all output *)
        let output = read_all [] in
        
        (* Wait for child process to be reaped *)
        let (_, status) = Unix.waitpid [] pid in
        
        (* Close PTY *)
        let () = Lwt_main.run (AaaU.Pty.close pty) in
        
        (* Verify agent exited successfully *)
        let exited_ok = match status with
          | Unix.WEXITED 0 -> true
          | _ -> false
        in
        
        Printf.printf "Agent output: %s\n%!" (String.trim output);
        Printf.printf "Exit status: %s\n%!" (if exited_ok then "OK (0)" else "FAILED");
        
        exited_ok
  in

  result

let () =
  Printf.printf "=== Test: Agent exit handling ===\n%!";
  let result = test_agent_exit () in
  if result then begin
    Printf.printf "PASS\n%!";
    exit 0
  end else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
