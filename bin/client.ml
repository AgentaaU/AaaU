(** Client entry point *)

open Lwt.Syntax
open Cmdliner

let write_all = AaaU.Client_io.write_all

let socket_path =
  let doc = "Server socket path" in
  Arg.(value & opt string "/var/run/aaau.sock" & info ["s"; "socket"] ~docv:"PATH" ~doc)

let session_id =
  let doc = "Existing session ID to join" in
  Arg.(value & opt (some string) None & info ["n"; "session"] ~docv:"ID" ~doc)

let readonly =
  let doc = "Read-only mode" in
  Arg.(value & flag & info ["r"; "readonly"] ~doc)

let program =
  let doc = "Program to run as agent (e.g., kimi-cli, /bin/bash)" in
  Arg.(value & opt (some string) None & info ["p"; "program"] ~docv:"PROGRAM" ~doc)

let program_alias =
  let aliases = [
    ("codex", "codex");
    ("claude", "claude");
  ] in
  let doc = "Shortcut alias for a predefined agent command" in
  Arg.(value & pos 0 (some (enum aliases)) None & info [] ~docv:"ALIAS" ~doc)

(* Get actual terminal size using ioctl *)
let get_terminal_size () =
  try
    AaaU.Pty.get_terminal_size Unix.stdout
  with _ ->
    (* Fallback to default if ioctl fails *)
    (24, 80)

(* Global reference for socket to send resize events *)
let socket_ref = ref None

let rec run_client_lwt socket_path session_id readonly program program_alias =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let requested_program =
    match (program, program_alias) with
    | Some _, Some _ ->
      Error "Cannot use ALIAS together with -p/--program"
    | Some raw, None -> Ok (Some raw)
    | None, Some alias -> Ok (AaaU.Command_line.expand_program_alias alias)
    | None, None -> Ok None
  in
  let program_spec =
    match requested_program with
    | Error e -> Error e
    | Ok None -> Ok None
    | Ok (Some raw) ->
      match AaaU.Command_line.split_command raw with
      | Ok (prog, args) -> Ok (Some (prog, args))
      | Error e -> Error e
  in
  match program_spec with
  | Error e ->
    Printf.eprintf "Invalid program string: %s\n%!" e;
    Lwt.return_unit
  | Ok program_spec ->
  (* Connect to server *)
  let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect socket (Unix.ADDR_UNIX socket_path) in

  (* Store socket reference for signal handler *)
  socket_ref := Some socket;

  (* Get terminal size for handshake *)
  let (rows, cols) = get_terminal_size () in
  
  (* Send handshake with terminal size - include newline for proper framing *)
  let handshake =
    match session_id with
    | Some id -> "SESSION:" ^ id
    | None ->
      match program_spec with
      | Some (prog, args) ->
        let payload =
          `Assoc [
            ("program", `String prog);
            ("args", `List (List.map (fun arg -> `String arg) args));
            ("rows", `Int rows);
            ("cols", `Int cols);
          ]
          |> Yojson.Safe.to_string
        in
        "NEW_JSON:" ^ payload
      | None -> Printf.sprintf "NEW:%d:%d" rows cols
  in
  let handshake_nl = handshake ^ "\n" in
  let* _ = Lwt_unix.write_string socket handshake_nl 0 (String.length handshake_nl) in

  let* handshake_response = AaaU.Client_io.read_handshake_response socket in
  match handshake_response with
  | AaaU.Client_io.Timeout ->
    Printf.eprintf "Server handshake timeout\n%!";
    Lwt.return_unit
  | AaaU.Client_io.Response (handshake_line, initial_output) ->
    if String.starts_with ~prefix:"SESSION:" handshake_line then begin
      (* Connected successfully, enter interactive mode *)
      if readonly then
        run_readonly socket ~initial_output
      else
        run_interactive socket ~initial_output
    end else begin
      (* Print error and exit *)
      Printf.eprintf "Server error: %s\n%!" handshake_line;
      Lwt.return_unit
    end

and run_readonly socket ~initial_output =
  (* Read-only mode: only receive, don't send *)
  let print_output data =
    if data <> "" && not (AaaU.Protocol.is_control data) then
      print_string data
  in
  print_output initial_output;
  let rec loop () =
    let buf = Bytes.create 4096 in
    let* n = Lwt_unix.read socket buf 0 4096 in
    if n = 0 then
      Lwt.return_unit
    else
      let data = Bytes.sub_string buf 0 n in
      print_output data;
      loop ()
  in
  loop ()

and run_interactive socket ~initial_output =
  (* Save original terminal attributes *)
  let old_tty = Unix.tcgetattr Unix.stdin in
  
  (* Set proper raw mode for transparent PTY forwarding *)
  (* The agent (opencode) manages its own screen state (alternate buffer, etc.) *)
  (* We just pass through all data transparently *)
  let new_tty = { old_tty with
    (* Input modes: disable all special processing *)
    c_ignbrk = false;
    c_brkint = false;
    c_ignpar = false;
    c_parmrk = false;
    c_inpck = false;
    c_istrip = false;
    c_inlcr = false;
    c_igncr = false;
    c_icrnl = false;
    c_ixon = false;
    c_ixoff = false;
    
    (* Output modes: keep output processing enabled for proper \r handling *)
    c_opost = true;
    
    (* Local modes: disable canonical mode, signals, echo *)
    c_isig = false;
    c_icanon = false;
    c_echo = false;
    c_echoe = false;
    c_echok = false;
    c_echonl = false;
    
    (* Block until at least 1 char is available *)
    c_vmin = 1;
    c_vtime = 0;
  } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_tty;

  (* Give session time to initialize *)
  let* () = Lwt_unix.sleep 0.1 in

  (* Send initial window size *)
  let (rows, cols) = get_terminal_size () in
  let resize_msg = AaaU.Protocol.encode_client
    (Resize { rows; cols })
  in
  let framed_resize = AaaU.Protocol.frame_message resize_msg in
  let* () = write_all socket framed_resize in

  (* Setup SIGWINCH handler for window resize *)
  let resize_cond = Lwt_condition.create () in
  let handle_winch _ = 
    Lwt.async (fun () -> 
      Lwt_condition.signal resize_cond ();
      Lwt.return_unit
    )
  in
  Sys.set_signal Sys.sigwinch (Signal_handle handle_winch);

  (* Exit condition for coordinating thread shutdown *)
  let exit_cond = Lwt_condition.create () in
  let should_exit = ref false in
  
  let signal_exit () =
    if not !should_exit then begin
      should_exit := true;
      Lwt_condition.broadcast exit_cond ()
    end
  in

  (* stdin → socket: Read user input and send to server *)
  let stdin_to_socket () =
    (* Use Lwt_unix with blocking semantics via VMIN=1 *)
    (* stdin is in raw mode with VMIN=1, VTIME=0 - blocks until 1 char available *)
    (* ~set_flags:false preserves blocking mode - Lwt will use thread pool *)
    let stdin_lwt = Lwt_unix.of_unix_file_descr ~set_flags:false Unix.stdin in
    let rec loop () =
      if !should_exit then Lwt.return_unit
      else
        (* Read available input - escape sequences need to be kept together *)
        let buf = Bytes.create 256 in
        Lwt.catch
          (fun () ->
            let* n = Lwt_unix.read stdin_lwt buf 0 256 in
            if n = 0 then begin
              signal_exit ();
              Lwt.return_unit
            end else
              let data = Bytes.sub_string buf 0 n in
              (* Pass raw bytes through - don't translate \r to \n *)
              let encoded = AaaU.Protocol.encode_client (AaaU.Protocol.Input data) in
              (* Frame the message with length prefix for proper demarcation *)
              let framed = AaaU.Protocol.frame_message encoded in
              (* Write with timeout to prevent blocking if server is slow *)
              let* () = Lwt.pick [
                (let* () = write_all socket framed in Lwt.return_unit);
                (let* () = Lwt_unix.sleep 5.0 in
                 Lwt.return_unit);
              ] in
              loop ())
          (fun _ ->
            (* Socket write failed or closed - agent may have exited *)
            signal_exit ();
            Lwt.return_unit)
    in
    loop ()
  in

  (* socket → stdout: Read from server and write to terminal *)
  let socket_to_stdout () =
    (* Use Lwt writes to avoid blocking the event loop *)
    (* Convert Unix.stdout to Lwt file descriptor *)
    let stdout_lwt = Lwt_unix.of_unix_file_descr ~set_flags:false Unix.stdout in
    let rec write_stdout data offset remaining =
      if remaining = 0 then Lwt.return_unit
      else
        let* written = Lwt_unix.write_string stdout_lwt data offset remaining in
        if written > 0 then
          write_stdout data (offset + written) (remaining - written)
        else
          Lwt.return_unit
    in
    let rec loop () =
      if !should_exit then Lwt.return_unit
      else
        let buf = Bytes.create 4096 in
        Lwt.catch
          (fun () ->
            let* n = Lwt_unix.read socket buf 0 4096 in
            if n = 0 then begin
              signal_exit ();
              (* Agent exited - give a moment for final output then exit *)
              let* () = Lwt_unix.sleep 0.1 in
              signal_exit ();
              Lwt.return_unit
            end else
              let data = Bytes.sub_string buf 0 n in
              (* Skip protocol control messages - they start with \x01 *)
              let* () =
                if not (AaaU.Protocol.is_control data) then
                  write_stdout data 0 (String.length data)
                else
                  Lwt.return_unit
              in
              loop ())
          (fun _ ->
            signal_exit ();
            Lwt.return_unit)
    in
    let* () =
      if initial_output <> "" && not (AaaU.Protocol.is_control initial_output) then
        write_stdout initial_output 0 (String.length initial_output)
      else
        Lwt.return_unit
    in
    loop ()
  in

  (* Handle resize events *)
  let resize_handler () =
    let rec loop () =
      if !should_exit then Lwt.return_unit
      else
        let* () = Lwt_condition.wait resize_cond in
        if !should_exit then Lwt.return_unit
        else
          let (rows, cols) = get_terminal_size () in
          let resize_msg = AaaU.Protocol.encode_client
            (Resize { rows; cols })
          in
          let framed_resize = AaaU.Protocol.frame_message resize_msg in
          Lwt.catch
            (fun () ->
              let* () = write_all socket framed_resize in
              loop ())
            (fun _ ->
              signal_exit ();
              Lwt.return_unit)
    in
    loop ()
  in

  (* Cleanup function *)
  let cleanup () =
    (* Restore terminal attributes *)
    Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_tty;
    (* Restore default SIGWINCH handler *)
    Sys.set_signal Sys.sigwinch Signal_default
  in

  (* Run all threads concurrently using Lwt.async *)
  Lwt.async (fun () -> stdin_to_socket ());
  Lwt.async (fun () -> socket_to_stdout ());
  Lwt.async (fun () -> resize_handler ());

  (* Wait for exit signal, then cleanup *)
  let run_all () =
    (* Wait for exit signal from any thread *)
    let* () = Lwt_condition.wait exit_cond in
    (* Small delay to ensure all output is written *)
    let* () = Lwt_unix.sleep 0.05 in
    (* Close socket to unblock any pending reads *)
    let* () = Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit) in
    cleanup ();
    Lwt.return_unit
  in

  Lwt.catch
    (fun () -> run_all ())
    (fun e ->
      cleanup ();
      Lwt.fail e)

let cmd =
  let doc = "Agent-as-User Bridge Client" in
  let info = Cmd.info "aaau-client" ~version:"0.1.0" ~doc in
  Cmd.v info Term.(const (fun a b c d e -> Lwt_main.run (run_client_lwt a b c d e))
    $ socket_path $ session_id $ readonly $ program $ program_alias)

let () = exit (Cmd.eval cmd)
