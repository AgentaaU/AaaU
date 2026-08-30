(** Server entry point *)

open Lwt.Syntax
open Cmdliner

(* Common arguments *)
let socket_path =
  let doc = "Unix socket path for client connections" in
  Arg.(value & opt string "/var/run/aaau/server.sock" & info ["s"; "socket"] ~docv:"PATH" ~doc)

let editor_socket_path =
  let doc = "Agent-only editor request socket path" in
  Arg.(value & opt string "/var/run/aaau/editor.sock" & info ["editor-socket"] ~docv:"PATH" ~doc)

let shared_group =
  let doc = "Group name for authorized users" in
  Arg.(value & opt string "aaau-users" & info ["g"; "group"] ~docv:"GROUP" ~doc)

let agent_user =
  let doc = "System user for running agents" in
  Arg.(value & opt string "agent" & info ["u"; "user"] ~docv:"USER" ~doc)

let log_dir =
  let doc = "Directory for audit logs" in
  Arg.(value & opt string "/var/log/aaau" & info ["l"; "log-dir"] ~docv:"DIR" ~doc)

(* Run subcommand *)
let daemonize =
  let doc = "Run as daemon" in
  Arg.(value & flag & info ["d"; "daemon"] ~doc)

let default_program =
  let doc = "Default program to run as agent (e.g., /bin/bash, kimi-cli)" in
  Arg.(value & opt string "/bin/bash" & info ["p"; "program"] ~docv:"PROGRAM" ~doc)

let lock_file =
  let doc = "Lock file path to prevent multiple instances" in
  Arg.(value & opt string "/var/run/aaau/aaau.lock" & info ["lock-file"] ~docv:"PATH" ~doc)

(* Lock file management *)
let lock_fd = ref None

let create_lock_file path =
  try
    let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
    (* Write PID to lock file *)
    let pid = string_of_int (Unix.getpid ()) in
    Unix.write_substring fd pid 0 (String.length pid) |> ignore;
    lock_fd := Some fd;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) ->
    (* Lock file exists, check if process is still running *)
    begin
      try
        let ch = open_in path in
        let line = input_line ch in
        close_in ch;
        let old_pid = int_of_string line in
        (* Check if process is still running *)
        Unix.kill old_pid 0;
        Error (Printf.sprintf "Another instance is already running (PID %d)" old_pid)
      with
      | End_of_file
      | Failure _ ->
        (* Stale lock file, remove it *)
        Unix.unlink path;
        (* Retry creating lock *)
        let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
        let pid = string_of_int (Unix.getpid ()) in
        Unix.write_substring fd pid 0 (String.length pid) |> ignore;
        lock_fd := Some fd;
        Ok ()
      | Unix.Unix_error (Unix.ESRCH, _, _) ->
        (* Process not running, stale lock *)
        Unix.unlink path;
        (* Retry creating lock *)
        let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
        let pid = string_of_int (Unix.getpid ()) in
        Unix.write_substring fd pid 0 (String.length pid) |> ignore;
        lock_fd := Some fd;
        Ok ()
    end
  | e ->
    Error (Printf.sprintf "Failed to create lock file: %s" (Printexc.to_string e))

let remove_lock_file path =
  match !lock_fd with
  | Some fd ->
      begin
        try Unix.close fd with _ -> ();
        lock_fd := None
      end
  | None ->
      ()
  ;
  begin
    try Unix.unlink path with _ -> ()
  end

let run_server socket_path editor_socket_path shared_group agent_user log_dir daemonize default_program lock_file_path =
  (* Running the bridge does not need root when it is started as the agent
     account.  Provisioning remains a separate privileged operation (init). *)
  if Unix.geteuid () <> 0 then begin
    let configured_uid = (Unix.getpwnam agent_user).Unix.pw_uid in
    if Unix.geteuid () <> configured_uid then begin
      Printf.eprintf "Error: run as the configured agent user '%s' (or root).\n%!"
        agent_user;
      exit 1
    end
  end;

  (* Create lock file to prevent multiple instances *)
  begin
    match create_lock_file lock_file_path with
    | Error msg ->
        Printf.eprintf "Error: %s\n%!" msg;
        exit 1
    | Ok () ->
        ()
  end;

  (* Initialize logging *)
  Logs.set_reporter (Logs.format_reporter ());
  Logs.set_level (Some Logs.Info);

  (* Daemonize *)
  if daemonize then begin
    (* Simplified daemonization *)
    let pid = Unix.fork () in
    if pid > 0 then exit 0;
    Unix.setsid () |> ignore;
    Unix.close Unix.stdin;
    Unix.close Unix.stdout;
    Unix.close Unix.stderr
  end;

  (* Create and start server *)
  let server = AaaU.Bridge.create
    ~socket_path
    ~editor_socket_path
    ~shared_group
    ~agent_user
    ~log_dir
    ~default_program
    ()
  in

  (* Signal handling *)
  let handle_signal _sig =
    Lwt.async (fun () ->
      let* () = Logs_lwt.info (fun m -> m "Shutting down...") in
      remove_lock_file lock_file_path;
      AaaU.Bridge.stop server
    )
  in

  Sys.set_signal Sys.sigterm (Signal_handle handle_signal);
  Sys.set_signal Sys.sigint (Signal_handle handle_signal);

  (* Start *)
  Lwt_main.run (AaaU.Bridge.start server)

let run_cmd =
  let doc = "Run the server" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run_server $ socket_path $ editor_socket_path $ shared_group $ agent_user $ log_dir $ daemonize $ default_program $ lock_file)

(* Init subcommand *)
let home_dir =
  let doc = "Home directory for agent user" in
  Arg.(value & opt string "/home/agent" & info ["h"; "home"] ~docv:"DIR" ~doc)

let shell =
  let doc = "Login shell for agent user" in
  Arg.(value & opt string "/bin/false" & info ["shell"] ~docv:"SHELL" ~doc)

(* Check if a user exists *)
let user_exists username =
  try
    let _ = Unix.getpwnam username in
    true
  with Not_found -> false

(* Check if a group exists *)
let group_exists groupname =
  try
    let _ = Unix.getgrnam groupname in
    true
  with Not_found -> false

(* Run setup utilities without a shell.  The init options are administrator
   supplied, but feeding them to Sys.command would still make spaces and shell
   metacharacters change the command being executed as root. *)
let run_command program args =
  Printf.printf "Running: %s\n%!" (String.concat " " (program :: args));
  try
    let pid = Unix.create_process program (Array.of_list (program :: args))
      Unix.stdin Unix.stdout Unix.stderr in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  with Unix.Unix_error (err, fn, arg) ->
    Printf.eprintf "Failed to run %s(%s): %s\n%!" fn arg
      (Unix.error_message err);
    false

let run_init agent_user shared_group socket_path log_dir home_dir shell =
  (* Check for root privileges *)
  if Unix.getuid () <> 0 then begin
    Printf.eprintf "Error: Need root permission to initialize environment.\n%!";
    Printf.eprintf "Please run with sudo.\n%!";
    exit 1
  end;
  
  Printf.printf "=== AaaU Environment Initialization ===\n\n%!";
  
  let exit_code = ref 0 in
  
  (* Step 1: Create shared group *)
  Printf.printf "[1/5] Checking shared group '%s'...\n%!" shared_group;
  if group_exists shared_group then begin
    Printf.printf "    Group '%s' already exists.\n%!" shared_group
  end else begin
    Printf.printf "    Creating group '%s'...\n%!" shared_group;
    if run_command "groupadd" ["--system"; shared_group] then
      Printf.printf "    Group created successfully.\n%!"
    else begin
      Printf.eprintf "    ERROR: Failed to create group '%s'.\n%!" shared_group;
      exit_code := 1
    end
  end;
  
  (* Step 2: Create agent user *)
  Printf.printf "\n[2/5] Checking agent user '%s'...\n%!" agent_user;
  if user_exists agent_user then begin
    Printf.printf "    User '%s' already exists.\n%!" agent_user;
    let account = Unix.getpwnam agent_user in
    let human_gid = (Unix.getgrnam shared_group).Unix.gr_gid in
    if account.Unix.pw_gid = human_gid then begin
      Printf.eprintf "    ERROR: agent primary group must differ from human group '%s'.\n%!" shared_group;
      exit_code := 1
    end;
    (* Remove legacy supplementary access to the human control group. *)
    ignore (run_command "gpasswd" ["-d"; agent_user; shared_group])
  end else begin
    Printf.printf "    Creating user '%s'...\n%!" agent_user;
    (* Create parent directory for home if it doesn't exist *)
    if not (Sys.file_exists home_dir) then begin
      Printf.printf "    Creating parent directory '%s'...\n%!" home_dir;
      ignore (run_command "mkdir" ["-p"; home_dir])
    end;
    (* Create home directory *)
    let home = Filename.concat home_dir agent_user in
    if run_command "useradd"
         ["--system"; "--user-group"; "--home-dir"; home;
          "--shell"; shell; "--create-home"; agent_user] then begin
      Printf.printf "    User created successfully.\n%!";
      (* Set ownership of home directory *)
      ignore (run_command "chown" [agent_user ^ ":" ^ agent_user; home])
    end else begin
      Printf.eprintf "    ERROR: Failed to create user '%s'.\n%!" agent_user;
      exit_code := 1
    end
  end;
  
  (* Step 3: Create socket directory *)
  Printf.printf "\n[3/5] Creating socket directory...\n%!";
  let socket_dir = Filename.dirname socket_path in
  if Sys.file_exists socket_dir then
    Printf.printf "    Directory '%s' already exists.\n%!" socket_dir
  else begin
    if run_command "mkdir" ["-p"; socket_dir] then begin
      Printf.printf "    Directory created.\n%!";
      (* Socket nodes enforce access; directory traversal is public. *)
      if group_exists shared_group then begin
        let gid = (Unix.getgrnam shared_group).Unix.gr_gid in
        Unix.chown socket_dir 0 gid;
        Unix.chmod socket_dir 0o755;
        Printf.printf "    Permissions set (root:%s 755).\n%!" shared_group
      end
    end else begin
      Printf.eprintf "    ERROR: Failed to create directory '%s'.\n%!" socket_dir;
      exit_code := 1
    end
  end;
  
  (* Step 4: Create log directory *)
  Printf.printf "\n[4/5] Creating log directory...\n%!";
  if Sys.file_exists log_dir then
    Printf.printf "    Directory '%s' already exists.\n%!" log_dir
  else begin
    if run_command "mkdir" ["-p"; log_dir] then begin
      Printf.printf "    Directory created.\n%!";
      Unix.chmod log_dir 0o750;
      Printf.printf "    Permissions set (root-only writes, 0750).\n%!"
    end else begin
      Printf.eprintf "    ERROR: Failed to create directory '%s'.\n%!" log_dir;
      exit_code := 1
    end
  end;
  
  (* Step 5: State the isolation invariant. *)
  Printf.printf "\n[5/5] Agent isolation configured.\n%!";
  Printf.printf "    '%s' is not granted human-group membership or sudo access.\n%!" agent_user;
  
  (* Summary *)
  Printf.printf "\n=== Initialization %s ===\n%!" 
    (if !exit_code = 0 then "Complete" else "Failed");
  Printf.printf "\nNext steps:\n%!";
  Printf.printf "  1. Add human users to group '%s':\n%!" shared_group;
  Printf.printf "       usermod -aG %s <username>\n%!" shared_group;
  Printf.printf "  2. Run the server:\n%!";
  Printf.printf "       aaau-server run\n%!";
  
  exit !exit_code

let init_cmd =
  let doc = "Initialize environment for Agent-as-User (creates users, groups, directories)" in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const run_init $ agent_user $ shared_group $ socket_path $ log_dir $ home_dir $ shell)

(* Main command *)
let main_cmd =
  let doc = "Agent-as-User PTY Bridge Server" in
  let info = Cmd.info "aaau-server" ~version:"0.1.0" ~doc in
  Cmd.group info [run_cmd; init_cmd]

let () = exit (Cmd.eval main_cmd)
