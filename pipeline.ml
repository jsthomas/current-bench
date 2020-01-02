(* This pipeline monitors a GitHub repository and uses Docker to build the
   latest version on the default branch. *)

open Current.Syntax
module Git = Current_git
module Github = Current_github
module Docker = Current_docker.Default
module Slack = Current_slack

let read_fpath p = Bos.OS.File.read p |> Rresult.R.error_msg_to_invalid_arg

let read_channel_uri p =
  read_fpath p |> String.trim |> Uri.of_string |> Current_slack.channel

(* Generate a Dockerfile for building all the opam packages in the build context. *)
let dockerfile ~base =
  let open Dockerfile in
  from (Docker.Image.hash base)
  @@ run
       "sudo apt-get install -qq -yy libffi-dev liblmdb-dev m4 pkg-config \
        gnuplot-x11"
  @@ copy ~src:[ "--chown=opam:opam ." ] ~dst:"index" ()
  @@ workdir "index"
  @@ run "opam install -y --deps-only -t ."
  @@ add ~src:[ "--chown=opam ." ] ~dst:"." ()
  @@ run
       "opam config exec -- dune build @@default bench/main.exe \
        bench/db_bench.exe"
  @@ run "eval $(opam env)"

let weekly = Current_cache.Schedule.v ~valid_for:(Duration.of_day 7) ()

let pipeline ~github ~repo ?output_file ?slack_path ?docker_cpu
    ?docker_numa_node ~docker_shm_size () =
  let tmp_source =
    Bos.OS.File.tmp "index-bench-result-%s.txt"
    |> Rresult.R.error_msg_to_invalid_arg
  in
  let tmp_target = Fpath.(v "/tmp" / filename tmp_source) in
  let head = Github.Api.head_commit github repo in
  let src = Git.fetch (Current.map Github.Api.Commit.id head) in
  let dockerfile =
    let+ base = Docker.pull ~schedule:weekly "ocaml/opam2" in
    dockerfile ~base
  in
  let image = Docker.build ~pull:false ~dockerfile (`Git src) in
  let docker_cpuset_cpus =
    match docker_cpu with
    | Some i -> [ "--cpuset-cpus"; string_of_int i ]
    | None -> []
  in
  let docker_cpuset_mems =
    match docker_numa_node with
    | Some i -> [ "--cpuset-mems"; string_of_int i ]
    | None -> []
  in
  let tmpfs =
    match docker_numa_node with
    | Some i ->
        [
          "--tmpfs";
          Fmt.str "/dev/shm:rw,noexec,nosuid,size=%dG,mpol=bind:%d"
            docker_shm_size i;
        ]
    | None ->
        [
          "--tmpfs";
          Fmt.str "/dev/shm:rw,noexec,nosuid,size=%dG" docker_shm_size;
        ]
  in
  let s =
    let run_args =
      [
        "--security-opt";
        "seccomp=./aslr_seccomp.json";
        "--mount";
        Fmt.str "type=bind,source=%a,target=%a" Fpath.pp tmp_source Fpath.pp
          tmp_target;
      ]
      @ tmpfs
      @ docker_cpuset_cpus
      @ docker_cpuset_mems
    in
    let+ () =
      Docker.run ~run_args image
        ~args:
          [
            "/usr/bin/setarch";
            "x86_64";
            "--addr-no-randomize";
            "_build/default/bench/db_bench.exe";
            "--bench";
            "index";
            "--json";
            Fmt.str "%a" Fpath.pp tmp_target;
          ]
    in
    (* Conditionally move the results to ?output_file *)
    let results_path =
      match output_file with
      | Some path ->
          Bos.OS.Path.move tmp_source path |> Rresult.R.error_msg_to_invalid_arg;
          path
      | None -> tmp_source
    in
    (* No need to read JSON if we're not publishing the results anywhere *)
    match slack_path with
    | Some p -> Some (p, read_fpath results_path)
    | None -> None
  in
  s
  |> Current.option_map (fun p ->
         Current.component "post"
         |> let** path, _ = p in
            let channel = read_channel_uri path in
            Slack.post channel ~key:"output" (Current.map snd p))
  |> Current.ignore_value

let webhooks = [ ("github", Github.input_webhook) ]

let main config mode github repo output_file slack_path docker_cpu
    docker_numa_node docker_shm_size () =
  let engine =
    Current.Engine.create ~config
      (pipeline ~github ~repo ?output_file ?slack_path ?docker_cpu
         ?docker_numa_node ~docker_shm_size)
  in
  Logging.run
    (Lwt.choose
       [ Current.Engine.thread engine; Current_web.run ~mode ~webhooks engine ])

(* Command-line parsing *)

open Cmdliner

let path = Arg.conv ~docv:"PATH" Fpath.(of_string, pp)

let output_file =
  let doc = "Output file where benchmark result should be stored." in
  Arg.(value & opt (some path) None & info [ "o"; "output" ] ~doc)

let slack_path =
  let doc =
    "File containing the Slack endpoint URI to use for result notifications."
  in
  Arg.(value & opt (some path) None & info [ "s"; "slack" ] ~doc)

let docker_cpu =
  let doc = "CPU/core that should run the benchmarks." in
  Arg.(value & opt (some int) None & info [ "docker-cpu" ] ~doc)

let docker_numa_node =
  let doc =
    "NUMA node to use for memory and tmpfs storage (should match CPU core if \
     enabled, see `lscpu`)"
  in
  Arg.(value & opt (some int) None & info [ "docker-numa-node" ] ~doc)

let docker_shm_size =
  let doc = "Size of tmpfs volume to be mounted in /dev/shm (in GB)." in
  Arg.(value & opt int 4 & info [ "docker-shm-size" ] ~doc)

let repo =
  Arg.required
  @@ Arg.pos 0 (Arg.some Github.Repo_id.cmdliner) None
  @@ Arg.info ~doc:"The GitHub repository (owner/name) to monitor." ~docv:"REPO"
       []

let setup_log =
  let init style_renderer level = Logging.init ?style_renderer ?level () in
  Term.(const init $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let cmd =
  let doc = "Monitor a GitHub repository." in
  ( Term.(
      const main
      $ Current.Config.cmdliner
      $ Current_web.cmdliner
      $ Current_github.Api.cmdliner
      $ repo
      $ output_file
      $ slack_path
      $ docker_cpu
      $ docker_numa_node
      $ docker_shm_size
      $ setup_log),
    Term.info "github" ~doc )

let () = Term.(exit @@ eval cmd)