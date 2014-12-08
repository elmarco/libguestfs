(* virt-resize
 * Copyright (C) 2010-2014 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

open Printf

open Common_gettext.Gettext

module G = Guestfs

open Common_utils

(* Minimum surplus before we create an extra partition. *)
let min_extra_partition = 10L *^ 1024L *^ 1024L

(* Command line argument parsing. *)
let prog = Filename.basename Sys.executable_name
let error fs = error ~prog fs

type align_first_t = [ `Never | `Always | `Auto ]

(* Source partition type. *)
type parttype = MBR | GPT

(* Data structure describing the source disk's partition layout.
 *
 * NOTE: For MBR, only primary/extended partitions are tracked here.
 * Logical partitions are contained within an extended partition, and
 * we don't track them (they are just copied within the extended
 * partition).  For the same reason we cannot resize logical partitions.
 *)
type partition = {
  p_name : string;               (* Device name, like /dev/sda1. *)
  p_part : G.partition;          (* SOURCE partition data from libguestfs. *)
  p_bootable : bool;             (* Is it bootable? *)
  p_id : partition_id;           (* Partition (MBR/GPT) ID. *)
  p_type : partition_content;    (* Content type and content size. *)
  p_label : string option;       (* Label/name. *)
  p_guid : string option;        (* Partition GUID (GPT only). *)

  (* What we're going to do: *)
  mutable p_operation : partition_operation;
  p_target_partnum : int;        (* TARGET partition number. *)
  p_target_start : int64;        (* TARGET partition start (sector num). *)
  p_target_end : int64;          (* TARGET partition end (sector num). *)
}
and partition_content =
  | ContentUnknown               (* undetermined *)
  | ContentPV of int64           (* physical volume (size of PV) *)
  | ContentFS of string * int64  (* mountable filesystem (FS type, FS size) *)
  | ContentExtendedPartition     (* MBR extended partition *)
and partition_operation =
  | OpCopy                       (* copy it as-is, no resizing *)
  | OpIgnore                     (* ignore it (create on target, but don't
                                    copy any content) *)
  | OpDelete                     (* delete it *)
  | OpResize of int64            (* resize it to the new size *)
and partition_id =
  | No_ID                        (* No identifier. *)
  | MBR_ID of int                (* MBR ID. *)
  | GPT_Type of string           (* GPT UUID. *)

type partition_type =
  | PrimaryPartition

let rec debug_partition p =
  eprintf "%s:\n" p.p_name;
  eprintf "\tpartition data: %ld %Ld-%Ld (%Ld bytes)\n"
    p.p_part.G.part_num p.p_part.G.part_start p.p_part.G.part_end
    p.p_part.G.part_size;
  eprintf "\tbootable: %b\n" p.p_bootable;
  eprintf "\tpartition ID: %s\n"
    (match p.p_id with
    | No_ID -> "(none)"
    | MBR_ID i -> sprintf "0x%x" i
    | GPT_Type i -> i
    );
  eprintf "\tcontent: %s\n" (string_of_partition_content p.p_type);
  eprintf "\tlabel: %s\n"
    (match p.p_label with
    | Some label -> label
    | None -> "(none)"
    );
  printf "\tGUID: %s\n"
    (match p.p_guid with
    | Some guid -> guid
    | None -> "(none)"
    )
and string_of_partition_content = function
  | ContentUnknown -> "unknown data"
  | ContentPV sz -> sprintf "LVM PV (%Ld bytes)" sz
  | ContentFS (fs, sz) -> sprintf "filesystem %s (%Ld bytes)" fs sz
  | ContentExtendedPartition -> "extended partition"
and string_of_partition_content_no_size = function
  | ContentUnknown -> "unknown data"
  | ContentPV _ -> "LVM PV"
  | ContentFS (fs, _) -> sprintf "filesystem %s" fs
  | ContentExtendedPartition -> "extended partition"

(* Data structure describing LVs on the source disk.  This is only
 * used if the user gave the --lv-expand option.
 *)
type logvol = {
  lv_name : string;
  lv_type : logvol_content;
  mutable lv_operation : logvol_operation
}
(* ContentPV, ContentExtendedPartition cannot occur here *)
and logvol_content = partition_content
and logvol_operation =
  | LVOpNone                     (* nothing *)
  | LVOpExpand                   (* expand it *)

let debug_logvol lv =
  eprintf "%s:\n" lv.lv_name;
  eprintf "\tcontent: %s\n" (string_of_partition_content lv.lv_type)

type expand_content_method =
  | PVResize | Resize2fs | NTFSResize | BtrfsFilesystemResize | XFSGrowFS

let string_of_expand_content_method = function
  | PVResize -> s_"pvresize"
  | Resize2fs -> s_"resize2fs"
  | NTFSResize -> s_"ntfsresize"
  | BtrfsFilesystemResize -> s_"btrfs-filesystem-resize"
  | XFSGrowFS -> s_"xfs_growfs"

(* Main program. *)
let main () =
  let infile, outfile, align_first, alignment, copy_boot_loader,
    debug_gc, deletes,
    dryrun, expand, expand_content, extra_partition, format, ignores,
    lv_expands, machine_readable, ntfsresize_force, output_format,
    quiet, resizes, resizes_force, shrink, sparse, trace, verbose =
    let display_version () =
      printf "virt-resize %s\n" Config.package_version;
      exit 0
    in

    let add xs s = xs := s :: !xs in

    let align_first = ref "auto" in
    let alignment = ref 128 in
    let copy_boot_loader = ref true in
    let debug_gc = ref false in
    let deletes = ref [] in
    let dryrun = ref false in
    let expand = ref "" in
    let set_expand s =
      if s = "" then error (f_"%s: empty --expand option") prog
      else if !expand <> "" then error (f_"--expand option given twice")
      else expand := s
    in
    let expand_content = ref true in
    let extra_partition = ref true in
    let format = ref "" in
    let ignores = ref [] in
    let lv_expands = ref [] in
    let machine_readable = ref false in
    let ntfsresize_force = ref false in
    let output_format = ref "" in
    let quiet = ref false in
    let resizes = ref [] in
    let resizes_force = ref [] in
    let shrink = ref "" in
    let set_shrink s =
      if s = "" then error (f_"empty --shrink option")
      else if !shrink <> "" then error (f_"--shrink option given twice")
      else shrink := s
    in
    let sparse = ref true in
    let trace = ref false in
    let verbose = ref false in

    let ditto = " -\"-" in
    let argspec = Arg.align [
      "--align-first", Arg.Set_string align_first, s_"never|always|auto" ^ " " ^ s_"Align first partition (default: auto)";
      "--alignment", Arg.Set_int alignment,   s_"sectors" ^ " " ^ s_"Set partition alignment (default: 128 sectors)";
      "--no-copy-boot-loader", Arg.Clear copy_boot_loader, " " ^ s_"Don't copy boot loader";
      "-d",        Arg.Set verbose,           " " ^ s_"Enable debugging messages";
      "--debug",   Arg.Set verbose,           ditto;
      "--debug-gc",Arg.Set debug_gc,          " " ^ s_"Debug GC and memory allocations";
      "--delete",  Arg.String (add deletes),  s_"part" ^ " " ^ s_"Delete partition";
      "--expand",  Arg.String set_expand,     s_"part" ^ " " ^ s_"Expand partition";
      "--no-expand-content", Arg.Clear expand_content, " " ^ s_"Don't expand content";
      "--no-extra-partition", Arg.Clear extra_partition, " " ^ s_"Don't create extra partition";
      "--format",  Arg.Set_string format,     s_"format" ^ " " ^ s_"Format of input disk";
      "--ignore",  Arg.String (add ignores),  s_"part" ^ " " ^ s_"Ignore partition";
      "--long-options", Arg.Unit display_long_options, " " ^ s_"List long options";
      "--lv-expand", Arg.String (add lv_expands), s_"lv" ^ " " ^ s_"Expand logical volume";
      "--LV-expand", Arg.String (add lv_expands), s_"lv" ^ ditto;
      "--lvexpand", Arg.String (add lv_expands), s_"lv" ^ ditto;
      "--LVexpand", Arg.String (add lv_expands), s_"lv" ^ ditto;
      "--machine-readable", Arg.Set machine_readable, " " ^ s_"Make output machine readable";
      "-n",        Arg.Set dryrun,            " " ^ s_"Don't perform changes";
      "--dryrun",  Arg.Set dryrun,            ditto;
      "--dry-run", Arg.Set dryrun,            ditto;
      "--ntfsresize-force", Arg.Set ntfsresize_force, " " ^ s_"Force ntfsresize";
      "--output-format", Arg.Set_string output_format, s_"format" ^ " " ^ s_"Format of output disk";
      "-q",        Arg.Set quiet,             " " ^ s_"Don't print the summary";
      "--quiet",   Arg.Set quiet,             ditto;
      "--resize",  Arg.String (add resizes),  s_"part=size" ^ " " ^ s_"Resize partition";
      "--resize-force", Arg.String (add resizes_force), s_"part=size" ^ " " ^ s_"Forcefully resize partition";
      "--shrink",  Arg.String set_shrink,     s_"part" ^ " " ^ s_"Shrink partition";
      "--no-sparse", Arg.Clear sparse,        " " ^ s_"Turn off sparse copying";
      "-v",        Arg.Set verbose,           " " ^ s_"Enable debugging messages";
      "--verbose", Arg.Set verbose,           ditto;
      "-V",        Arg.Unit display_version,  " " ^ s_"Display version and exit";
      "--version", Arg.Unit display_version,  ditto;
      "-x",        Arg.Set trace,             " " ^ s_"Enable tracing of libguestfs calls";
    ] in
    long_options := argspec;
    let disks = ref [] in
    let anon_fun s = disks := s :: !disks in
    let usage_msg =
      sprintf (f_"\
%s: resize a virtual machine disk

A short summary of the options is given below.  For detailed help please
read the man page virt-resize(1).
")
        prog in
    Arg.parse argspec anon_fun usage_msg;

    let verbose = !verbose in
    if verbose then (
      eprintf "command line:";
      List.iter (eprintf " %s") (Array.to_list Sys.argv);
      prerr_newline ()
    );

    (* Dereference the rest of the args. *)
    let alignment = !alignment in
    let copy_boot_loader = !copy_boot_loader in
    let debug_gc = !debug_gc in
    let deletes = List.rev !deletes in
    let dryrun = !dryrun in
    let expand = match !expand with "" -> None | str -> Some str in
    let expand_content = !expand_content in
    let extra_partition = !extra_partition in
    let format = match !format with "" -> None | str -> Some str in
    let ignores = List.rev !ignores in
    let lv_expands = List.rev !lv_expands in
    let machine_readable = !machine_readable in
    let ntfsresize_force = !ntfsresize_force in
    let output_format = match !output_format with "" -> None | str -> Some str in
    let quiet = !quiet in
    let resizes = List.rev !resizes in
    let resizes_force = List.rev !resizes_force in
    let shrink = match !shrink with "" -> None | str -> Some str in
    let sparse = !sparse in
    let trace = !trace in

    if alignment < 1 then
      error (f_"alignment cannot be < 1");
    let alignment = Int64.of_int alignment in

    let align_first =
      match !align_first with
      | "never" -> `Never
      | "always" -> `Always
      | "auto" -> `Auto
      | _ ->
        error (f_"unknown --align-first option: use never|always|auto") in

    (* No arguments and machine-readable mode?  Print out some facts
     * about what this binary supports.  We only need to print out new
     * things added since this option, or things which depend on features
     * of the appliance.
     *)
    if !disks = [] && machine_readable then (
      printf "virt-resize\n";
      printf "ntfsresize-force\n";
      printf "32bitok\n";
      printf "128-sector-alignment\n";
      printf "alignment\n";
      printf "align-first\n";
      printf "infile-uri\n";
      let g = new G.guestfs () in
      g#add_drive "/dev/null";
      g#launch ();
      if g#feature_available [| "ntfsprogs"; "ntfs3g" |] then
        printf "ntfs\n";
      if g#feature_available [| "btrfs" |] then
        printf "btrfs\n";
      if g#feature_available [| "xfs" |] then
        printf "xfs\n";
      exit 0
    );

    (* Verify we got exactly 2 disks. *)
    let infile, outfile =
      match List.rev !disks with
      | [infile; outfile] -> infile, outfile
      | _ ->
        error (f_"usage is: %s [--options] indisk outdisk") prog in

    (* Simple-minded check that the user isn't trying to use the
     * same disk for input and output.
     *)
    if infile = outfile then
      error (f_"you cannot use the same disk image for input and output");

    (* infile can be a URI. *)
    let infile =
      try (infile, URI.parse_uri infile)
      with Invalid_argument "URI.parse_uri" ->
        error (f_"error parsing URI '%s'. Look for error messages printed above.")
          infile in

    infile, outfile, align_first, alignment, copy_boot_loader,
    debug_gc, deletes,
    dryrun, expand, expand_content, extra_partition, format, ignores,
    lv_expands, machine_readable, ntfsresize_force, output_format,
    quiet, resizes, resizes_force, shrink, sparse, trace, verbose in

  (* Default to true, since NTFS/btrfs/XFS support are usually available. *)
  let ntfs_available = ref true in
  let btrfs_available = ref true in
  let xfs_available = ref true in

  (* Add in and out disks to the handle and launch. *)
  let connect_both_disks () =
    let g = new G.guestfs () in
    if trace then g#set_trace true;
    if verbose then g#set_verbose true;
    let _, { URI.path = path; protocol = protocol;
             server = server; username = username;
             password = password } = infile in
    g#add_drive ?format ~readonly:true ~protocol ?server ?username ?secret:password path;
    (* The output disk is being created, so use cache=unsafe here. *)
    g#add_drive ?format:output_format ~readonly:false ~cachemode:"unsafe"
      outfile;
    if not quiet then Progress.set_up_progress_bar ~machine_readable g;
    g#launch ();

    (* Set the filter to /dev/sda, in case there are any rogue
     * PVs lying around on the target disk.
     *)
    g#lvm_set_filter [|"/dev/sda"|];

    (* Update features available in the daemon. *)
    ntfs_available := g#feature_available [|"ntfsprogs"; "ntfs3g"|];
    btrfs_available := g#feature_available [|"btrfs"|];
    xfs_available := g#feature_available [|"xfs"|];

    g
  in

  let g =
    if not quiet then
      printf (f_"Examining %s ...\n%!") (fst infile);

    let g = connect_both_disks () in

    g in

  (* Get the size in bytes of each disk.
   *
   * Originally we computed this by looking at the same of the host file,
   * but of course this failed for qcow2 images (RHBZ#633096).  The right
   * way to do it is with g#blockdev_getsize64.
   *)
  let sectsize, insize, outsize =
    let sectsize = Int64.of_int (g#blockdev_getss "/dev/sdb") in
    let insize = g#blockdev_getsize64 "/dev/sda" in
    let outsize = g#blockdev_getsize64 "/dev/sdb" in
    if verbose then (
      eprintf "%s size %Ld bytes\n" (fst infile) insize;
      eprintf "%s size %Ld bytes\n" outfile outsize
    );
    sectsize, insize, outsize in

  let max_bootloader =
    (* In reality the number of sectors containing boot loader data will be
     * less than this (although Windows 7 defaults to putting the first
     * partition on sector 2048, and has quite a large boot loader).
     *
     * However make this large enough to be sure that we have copied over
     * the boot loader.  We could also do this by looking for the sector
     * offset of the first partition.
     *
     * It doesn't matter if we copy too much.
     *)
    4096 * 512 in

  (* Check the disks are at least as big as the bootloader. *)
  if insize < Int64.of_int max_bootloader then
    error (f_"%s: file is too small to be a disk image (%Ld bytes)")
      (fst infile) insize;
  if outsize < Int64.of_int max_bootloader then
    error (f_"%s: file is too small to be a disk image (%Ld bytes)")
      outfile outsize;

  (* Get the source partition type. *)
  let parttype, parttype_string =
    let pt = g#part_get_parttype "/dev/sda" in
    if verbose then eprintf "partition table type: %s\n%!" pt;

    match pt with
    | "msdos" -> MBR, "msdos"
    | "gpt" -> GPT, "gpt"
    | _ ->
      error (f_"%s: unknown partition table type\nvirt-resize only supports MBR (DOS) and GPT partition tables.")
        (fst infile) in

  (* Build a data structure describing the source disk's partition layout. *)
  let get_partition_content =
    let pvs_full = Array.to_list (g#pvs_full ()) in
    fun dev ->
      try
        let fs = g#vfs_type dev in
        if fs = "unknown" then
          ContentUnknown
        else if fs = "LVM2_member" then (
          let rec loop = function
            | [] ->
              error (f_"%s: physical volume not returned by pvs_full") dev
            | pv :: _ when g#canonical_device_name pv.G.pv_name = dev ->
              ContentPV pv.G.pv_size
            | _ :: pvs -> loop pvs
          in
          loop pvs_full
        )
        else (
          g#mount_ro dev "/";
          let stat = g#statvfs "/" in
          g#umount "/";
          let size = stat.G.bsize *^ stat.G.blocks in
          ContentFS (fs, size)
        )
      with
        G.Error _ -> ContentUnknown
  in

  let is_extended_partition = function
    | MBR_ID (0x05|0x0f) -> true
    | MBR_ID _ | GPT_Type _ | No_ID -> false
  in

  let find_partitions part_type =
    let parts = Array.to_list (g#part_list "/dev/sda") in

    (* Filter out logical partitions.  See note above. *)
    let parts =
      match part_type with
      (* for GPT, all partitions are regarded as Primary Partition,
       * e.g. there is no Extended Partition or Logical Partition. *)
      | PrimaryPartition ->
        List.filter (fun p -> parttype <> MBR || p.G.part_num <= 4_l)
        parts in

    let partitions =
      List.map (
        fun ({ G.part_num = part_num } as part) ->
          let part_num = Int32.to_int part_num in
          let name = sprintf "/dev/sda%d" part_num in
          let bootable = g#part_get_bootable "/dev/sda" part_num in
          let id =
            match parttype with
            | GPT ->
              (try GPT_Type (g#part_get_gpt_type "/dev/sda" part_num)
              with G.Error _ -> No_ID)
            | MBR ->
              (try MBR_ID (g#part_get_mbr_id "/dev/sda" part_num)
              with G.Error _ -> No_ID) in
          let typ =
            if is_extended_partition id then ContentExtendedPartition
            else get_partition_content name in
          let label =
            try Some (g#part_get_name "/dev/sda" part_num)
            with G.Error _ -> None in
          let guid =
            match parttype with
            | MBR -> None
            | GPT ->
              try Some (g#part_get_gpt_guid "/dev/sda" part_num)
              with G.Error _ -> None in

          { p_name = name; p_part = part;
            p_bootable = bootable; p_id = id; p_type = typ;
            p_label = label; p_guid = guid;
            p_operation = OpCopy; p_target_partnum = 0;
            p_target_start = 0L; p_target_end = 0L }
      ) parts in

    (* Check content isn't larger than partitions.  If it is then
     * something has gone wrong and we shouldn't continue.  Old
     * virt-resize didn't do these checks.
     *)
    List.iter (
      function
      | { p_name = name; p_part = { G.part_size = size };
          p_type = ContentPV pv_size }
          when size < pv_size ->
        error (f_"%s: partition size %Ld < physical volume size %Ld")
          name size pv_size
      | { p_name = name; p_part = { G.part_size = size };
          p_type = ContentFS (_, fs_size) }
          when size < fs_size ->
        error (f_"%s: partition size %Ld < filesystem size %Ld")
          name size fs_size
      | _ -> ()
    ) partitions;

    (* Check partitions don't overlap. *)
    let rec loop end_of_prev = function
      | [] -> ()
      | { p_name = name; p_part = { G.part_start = part_start } } :: _
          when end_of_prev > part_start ->
        error (f_"%s: this partition overlaps the previous one") name
      | { p_part = { G.part_end = part_end } } :: parts -> loop part_end parts
    in
    loop 0L partitions;

    partitions in

  let partitions = find_partitions PrimaryPartition in

  if verbose then (
    eprintf "%d partitions found\n" (List.length partitions);
    List.iter debug_partition partitions
    );

  (* Build a data structure describing LVs on the source disk. *)
  let lvs =
    let lvs = Array.to_list (g#lvs ()) in

    let lvs = List.map (
      fun name ->
        let typ = get_partition_content name in
        assert (
          match typ with
          | ContentPV _ | ContentExtendedPartition -> false
          | ContentUnknown | ContentFS _ -> true
        );

        { lv_name = name; lv_type = typ; lv_operation = LVOpNone }
    ) lvs in

    if verbose then (
      eprintf "%d logical volumes found\n" (List.length lvs);
      List.iter debug_logvol lvs
    );

    lvs in

  (* These functions tell us if we know how to expand the content of
   * a particular partition or LV, and what method to use.
   *)
  let can_expand_content =
    if expand_content then
      function
      | ContentUnknown -> false
      | ContentPV _ -> true
      | ContentFS (("ext2"|"ext3"|"ext4"), _) -> true
      | ContentFS (("ntfs"), _) when !ntfs_available -> true
      | ContentFS (("btrfs"), _) when !btrfs_available -> true
      | ContentFS (("xfs"), _) when !xfs_available -> true
      | ContentFS (fs, _) ->
        if verbose then
          eprintf "Unknown/unavailable method for expanding filesystem %s\n"
            fs;
        false
      | ContentExtendedPartition -> false
    else
      fun _ -> false

  and expand_content_method =
    if expand_content then
      function
      | ContentUnknown -> assert false
      | ContentPV _ -> PVResize
      | ContentFS (("ext2"|"ext3"|"ext4"), _) -> Resize2fs
      | ContentFS (("ntfs"), _) when !ntfs_available -> NTFSResize
      | ContentFS (("btrfs"), _) when !btrfs_available -> BtrfsFilesystemResize
      | ContentFS (("xfs"), _) when !xfs_available -> XFSGrowFS
      | ContentFS (_, _) -> assert false
      | ContentExtendedPartition -> assert false
    else
      fun _ -> assert false
  in

  (* Helper function to locate a partition given what the user might
   * type on the command line.  It also gives errors for partitions
   * that the user has asked to be ignored or deleted.
   *)
  let find_partition =
    let hash = Hashtbl.create 13 in
    List.iter (fun ({ p_name = name } as p) -> Hashtbl.add hash name p)
      partitions;
    fun ~option name ->
      let name =
        if String.length name < 5 || String.sub name 0 5 <> "/dev/" then
          "/dev/" ^ name
        else
          name in
      let name = g#canonical_device_name name in

      let partition =
        try Hashtbl.find hash name
        with Not_found ->
          error (f_"%s: partition not found in the source disk image (this error came from '%s' option on the command line).  Try running this command: virt-filesystems --partitions --long -a %s")
          name option (fst infile) in

      if partition.p_operation = OpIgnore then
        error (f_"%s: partition already ignored, you cannot use it in '%s' option")
          name option;

      if partition.p_operation = OpDelete then
        error (f_"%s: partition already deleted, you cannot use it in '%s' option")
          name option;

      partition in

  (* Handle --ignore option. *)
  List.iter (
    fun dev ->
      let p = find_partition ~option:"--ignore" dev in
      p.p_operation <- OpIgnore
  ) ignores;

  (* Handle --delete option. *)
  List.iter (
    fun dev ->
      let p = find_partition ~option:"--delete" dev in
      p.p_operation <- OpDelete
  ) deletes;

  (* Helper function to mark a partition for resizing.  It prevents the
   * user from trying to mark the same partition twice.  If the force
   * flag is given, then we will allow the user to shrink the partition
   * even if we think that would destroy the content.
   *)
  let mark_partition_for_resize ~option ?(force = false) p newsize =
    let name = p.p_name in
    let oldsize = p.p_part.G.part_size in

    (match p.p_operation with
    | OpResize _ ->
      error (f_"%s: this partition has already been marked for resizing")
        name
    | OpIgnore | OpDelete ->
       (* This error should have been caught already by find_partition ... *)
      error (f_"%s: this partition has already been ignored or deleted")
        name
    | OpCopy -> ()
    );

    (* Only do something if the size will change. *)
    if oldsize <> newsize then (
      let bigger = newsize > oldsize in

      if not bigger && not force then (
        (* Check if this contains filesystem content, and how big that is
         * and whether we will destroy any content by shrinking this.
         *)
        match p.p_type with
        | ContentUnknown ->
          error (f_"%s: This partition has unknown content which might be damaged by shrinking it.  If you want to shrink this partition, you need to use the '--resize-force' option, but that could destroy any data on this partition.  (This error came from '%s' option on the command line.)")
            name option
        | ContentPV size when size > newsize ->
          error (f_"%s: This partition contains an LVM physical volume which will be damaged by shrinking it below %Ld bytes (user asked to shrink it to %Ld bytes).  If you want to shrink this partition, you need to use the '--resize-force' option, but that could destroy any data on this partition.  (This error came from '%s' option on the command line.)")
            name size newsize option
        | ContentPV _ -> ()
        | ContentFS (fstype, size) when size > newsize ->
          error (f_"%s: This partition contains a %s filesystem which will be damaged by shrinking it below %Ld bytes (user asked to shrink it to %Ld bytes).  If you want to shrink this partition, you need to use the '--resize-force' option, but that could destroy any data on this partition.  (This error came from '%s' option on the command line.)")
            name fstype size newsize option
        | ContentFS _ -> ()
        | ContentExtendedPartition ->
          error (f_"%s: This extended partition contains logical partitions which might be damaged by shrinking it.  If you want to shrink this partition, you need to use the '--resize-force' option, but that could destroy logical partitions within this partition.  (This error came from '%s' option on the command line.)")
            name option
      );

      p.p_operation <- OpResize newsize
    )
  in

  (* Handle --resize and --resize-force options. *)
  let do_resize ~option ?(force = false) arg =
    (* Argument is "dev=size". *)
    let dev, sizefield =
      try
        let i = String.index arg '=' in
        let n = String.length arg - (i+1) in
        if n == 0 then raise Not_found;
        String.sub arg 0 i, String.sub arg (i+1) n
      with Not_found ->
        error (f_"%s: missing size field in '%s' option") arg option in

    let p = find_partition ~option dev in

    (* Parse the size field. *)
    let oldsize = p.p_part.G.part_size in
    let newsize = parse_resize ~prog oldsize sizefield in

    if newsize <= 0L then
      error (f_"%s: new partition size is zero or negative") dev;

    mark_partition_for_resize ~option ~force p newsize
  in

  List.iter (do_resize ~option:"--resize") resizes;
  List.iter (do_resize ~option:"--resize-force" ~force:true) resizes_force;

  (* Helper function calculates the surplus space, given the total
   * required so far for the current partition layout, compared to
   * the size of the target disk.  If the return value >= 0 then it's
   * a surplus, if it is < 0 then it's a deficit.
   *)
  let calculate_surplus () =
    (* We need some overhead for partitioning. *)
    let overhead =
      let maxl64 = List.fold_left max 0L in

      let nr_partitions = List.length partitions in

      let gpt_start_sects = 64L in
      let gpt_end_sects = gpt_start_sects in

      let first_part_start_sects =
        match partitions with
        | { p_part = { G.part_start = start }} :: _ ->
          start /^ sectsize
        | [] -> 0L in

      let max_bootloader_sects = Int64.of_int max_bootloader /^ 512L in

      (* Size of the unpartitioned space before the first partition. *)
      let start_overhead_sects =
        maxl64 [gpt_start_sects; max_bootloader_sects; first_part_start_sects] in

      (* Maximum space lost because of alignment of partitions. *)
      let alignment_sects = alignment *^ Int64.of_int (nr_partitions + 1) in

      (* Add up the total max. overhead. *)
      let overhead_sects =
        start_overhead_sects +^ alignment_sects +^ gpt_end_sects in
      sectsize *^ overhead_sects in

    let required = List.fold_left (
      fun total p ->
        let newsize =
          match p.p_operation with
          | OpCopy | OpIgnore -> p.p_part.G.part_size
          | OpDelete -> 0L
          | OpResize newsize -> newsize in
        total +^ newsize
    ) 0L partitions in

    let surplus = outsize -^ (required +^ overhead) in

    if verbose then
      eprintf "calculate surplus: outsize=%Ld required=%Ld overhead=%Ld surplus=%Ld\n%!"
        outsize required overhead surplus;

    surplus
  in

  (* Handle --expand and --shrink options. *)
  if expand <> None && shrink <> None then
    error (f_"you cannot use options --expand and --shrink together");

  if expand <> None || shrink <> None then (
    let surplus = calculate_surplus () in

    if verbose then
      eprintf "surplus before --expand or --shrink: %Ld\n" surplus;

    (match expand with
     | None -> ()
     | Some dev ->
         if surplus < 0L then
           error (f_"You cannot use --expand when there is no surplus space to expand into.  You need to make the target disk larger by at least %s.")
             (human_size (Int64.neg surplus));

         let option = "--expand" in
         let p = find_partition ~option dev in
         let oldsize = p.p_part.G.part_size in
         mark_partition_for_resize ~option p (oldsize +^ surplus)
    );
    (match shrink with
     | None -> ()
     | Some dev ->
         if surplus > 0L then
           error (f_"You cannot use --shrink when there is no deficit (see 'deficit' in the virt-resize(1) man page).");

         let option = "--shrink" in
         let p = find_partition ~option dev in
         let oldsize = p.p_part.G.part_size in
         mark_partition_for_resize ~option p (oldsize +^ surplus)
    )
  );

  (* Calculate the final surplus.
   * At this point, this number must be >= 0.
   *)
  let surplus =
    let surplus = calculate_surplus () in

    if surplus < 0L then (
      let deficit = Int64.neg surplus in
      error (f_"There is a deficit of %Ld bytes (%s).  You need to make the target disk larger by at least this amount or adjust your resizing requests.")
      deficit (human_size deficit)
    );

    surplus in

  (* Mark the --lv-expand LVs. *)
  let hash = Hashtbl.create 13 in
  List.iter (fun ({ lv_name = name } as lv) -> Hashtbl.add hash name lv) lvs;

  List.iter (
    fun name ->
      let lv =
        try Hashtbl.find hash name
        with Not_found ->
          error (f_"%s: logical volume not found in the source disk image (this error came from '--lv-expand' option on the command line).  Try running this command: virt-filesystems --logical-volumes --long -a %s")
            name (fst infile) in
      lv.lv_operation <- LVOpExpand
  ) lv_expands;

  (* Print a summary of what we will do. *)
  flush stderr;

  if not quiet then (
    printf "**********\n\n";
    printf "Summary of changes:\n\n";

    let rec print_summary p =
        let text =
          match p.p_operation with
          | OpCopy ->
              sprintf (f_"%s: This partition will be left alone.") p.p_name
          | OpIgnore ->
              sprintf (f_"%s: This partition will be created, but the contents will be ignored (ie. not copied to the target).") p.p_name
          | OpDelete ->
              sprintf (f_"%s: This partition will be deleted.") p.p_name
          | OpResize newsize ->
              sprintf (f_"%s: This partition will be resized from %s to %s.")
                p.p_name (human_size p.p_part.G.part_size) (human_size newsize) ^
              if can_expand_content p.p_type then (
                sprintf (f_"  The %s on %s will be expanded using the '%s' method.")
                  (string_of_partition_content_no_size p.p_type)
                  p.p_name
                  (string_of_expand_content_method
                     (expand_content_method p.p_type))
              ) else "" in

        wrap ~indent:4 (text ^ "\n\n") in

    List.iter print_summary partitions;

    List.iter (
      fun ({ lv_name = name } as lv) ->
        match lv.lv_operation with
        | LVOpNone -> ()
        | LVOpExpand ->
            let text =
              sprintf (f_"%s: This logical volume will be expanded to maximum size.")
                name ^
              if can_expand_content lv.lv_type then (
                sprintf (f_"  The %s on %s will be expanded using the '%s' method.")
                  (string_of_partition_content_no_size lv.lv_type)
                  name
                  (string_of_expand_content_method
                     (expand_content_method lv.lv_type))
              ) else "" in

            wrap ~indent:4 (text ^ "\n\n")
    ) lvs;

    if surplus > 0L then (
      let text =
        sprintf (f_"There is a surplus of %s.") (human_size surplus) ^
        if extra_partition then (
          if surplus >= min_extra_partition then
            s_"  An extra partition will be created for the surplus."
          else
            s_"  The surplus space is not large enough for an extra partition to be created and so it will just be ignored."
        ) else
          s_"  The surplus space will be ignored.  Run a partitioning program in the guest to partition this extra space if you want." in

      wrap (text ^ "\n\n")
    );

    printf "**********\n";
    flush stdout
  );

  if dryrun then exit 0;

  (* Create a partition table.
   *
   * We *must* do this before copying the bootloader across, and copying
   * the bootloader must be careful not to disturb this partition table
   * (RHBZ#633766).  There are two reasons for this:
   *
   * (1) The 'parted' library is stupid and broken.  In many ways.  In
   * this particular instance the stupid and broken bit is that it
   * overwrites the whole boot sector when initializating a partition
   * table.  (Upstream don't consider this obvious problem to be a bug).
   *
   * (2) GPT has a backup partition table located at the end of the disk.
   * It's non-movable, because the primary GPT contains fixed references
   * to both the size of the disk and the backup partition table at the
   * end.  This would be a problem for any resize that didn't either
   * carefully move the backup GPT (and rewrite those references) or
   * recreate the whole partition table from scratch.
   *)
  let g =
    (* Try hard to initialize the partition table.  This might involve
     * relaunching another handle.
     *)
    if not quiet then
      printf (f_"Setting up initial partition table on %s ...\n%!") outfile;

    let last_error = ref "" in
    let rec initialize_partition_table g attempts =
      let ok =
        try g#part_init "/dev/sdb" parttype_string; true
        with G.Error error -> last_error := error; false in
      if ok then g, true
      else if attempts > 0 then (
        g#zero "/dev/sdb";
        g#shutdown ();
        g#close ();

        let g = connect_both_disks () in
        initialize_partition_table g (attempts-1)
      )
      else g, false
    in

    let g, ok = initialize_partition_table g 5 in
    if not ok then
      error (f_"Failed to initialize the partition table on the target disk.  You need to wipe or recreate the target disk and then run virt-resize again.\n\nThe underlying error was: %s") !last_error;

    g in

  (* Copy the bootloader across.
   * Don't disturb the partition table that we just wrote.
   * https://secure.wikimedia.org/wikipedia/en/wiki/Master_Boot_Record
   * https://secure.wikimedia.org/wikipedia/en/wiki/GUID_Partition_Table
   *)
  if copy_boot_loader then (
    let bootsect = g#pread_device "/dev/sda" 446 0L in
    if String.length bootsect < 446 then
      error (f_"pread-device: short read");
    ignore (g#pwrite_device "/dev/sdb" bootsect 0L);

    let start =
      if parttype <> GPT then 512L
      else
        (* With 512 byte sectors, GPT looks like:
         *    512 bytes   sector 0       protective MBR
         *   1024 bytes   sector 1       GPT header
         *  17408 bytes   sectors 2-33   GPT entries (up to 128 x 128 bytes)
         *
         * With 4K sectors, GPT puts more entries in each sector, so
         * the partition table looks like this:
         *   4096 bytes   sector 0       protective MBR
         *   8192 bytes   sector 1       GPT header
         *  24576 bytes   sectors 2-5    GPT entries (up to 128 x 128 bytes)
         *
         * qemu doesn't support 4k sectors yet, so let's just use the
         * 512 sector number for now.
         *)
        17408L in

    let loader = g#pread_device "/dev/sda" max_bootloader start in
    if String.length loader < max_bootloader then
      error (f_"pread-device: short read");
    ignore (g#pwrite_device "/dev/sdb" loader start)
  );

  (* Are we going to align the first partition and fix the bootloader? *)
  let align_first_partition_and_fix_bootloader =
    (* Bootloaders that we know how to fix:
     *  - first partition is NTFS, and
     *  - first partition is bootable, and
     *  - only one partition (ie. not Win Vista and later), and
     *  - it's not already aligned to some small value (no point
     *      moving it around unnecessarily)
     *)
    let rec can_fix_boot_loader () =
      match partitions with
      | [ { p_part = { G.part_start = start };
            p_type = ContentFS ("ntfs", _);
            p_bootable = true;
            p_operation = OpCopy | OpIgnore | OpResize _ } ]
          when not_aligned_enough start -> true
      | _ -> false
    and not_aligned_enough start =
      let alignment = alignment_of start in
      alignment < 12                    (* < 4K alignment *)
    and alignment_of = function
      | 0L -> 64
      | n when n &^ 1L = 1L -> 0
      | n -> 1 + alignment_of (n /^ 2L)
    in

    match align_first, can_fix_boot_loader () with
    | `Never, _
    | `Auto, false -> false
    | `Always, _
    | `Auto, true -> true in

  if verbose then
    eprintf "align_first_partition_and_fix_bootloader = %b\n%!"
      align_first_partition_and_fix_bootloader;

  (* Repartition the target disk. *)

  (* Calculate the location of the partitions on the target disk.  This
   * also removes from the list any partitions that will be deleted, so
   * the final list just contains partitions that need to be created
   * on the target.
   *)
  let rec calculate_target_partitions partnum start ~create_surplus = function
    | p :: ps ->
      (match p.p_operation with
      | OpDelete ->
        calculate_target_partitions partnum start ~create_surplus ps (* skip p *)

      | OpIgnore | OpCopy ->          (* same size *)
        (* Size in sectors. *)
        let size = div_roundup64 p.p_part.G.part_size sectsize in
        (* Start of next partition + alignment. *)
        let end_ = start +^ size in
        let next = roundup64 end_ alignment in

        if verbose then
          eprintf "target partition %d: ignore or copy: start=%Ld end=%Ld\n%!"
            partnum start (end_ -^ 1L);

        { p with p_target_start = start; p_target_end = end_ -^ 1L;
          p_target_partnum = partnum } ::
          calculate_target_partitions (partnum+1) next ~create_surplus ps

      | OpResize newsize ->           (* resized partition *)
        (* New size in sectors. *)
        let size = div_roundup64 newsize sectsize in
        (* Start of next partition + alignment. *)
        let next = start +^ size in
        let next = roundup64 next alignment in

        if verbose then
          eprintf "target partition %d: resize: newsize=%Ld start=%Ld end=%Ld\n%!"
            partnum newsize start (next -^ 1L);

        { p with p_target_start = start; p_target_end = next -^ 1L;
          p_target_partnum = partnum } ::
          calculate_target_partitions (partnum+1) next ~create_surplus ps
      )

    | [] ->
      (* Create the surplus partition if there is room for it. *)
      if create_surplus && extra_partition && surplus >= min_extra_partition then (
        [ {
          (* Since this partition has no source, this data is
           * meaningless and not used since the operation is
           * OpIgnore.
           *)
          p_name = "";
          p_part = { G.part_num = 0l; part_start = 0L; part_end = 0L;
                     part_size = 0L };
          p_bootable = false; p_id = No_ID; p_type = ContentUnknown;
          p_label = None; p_guid = None;

          (* Target information is meaningful. *)
          p_operation = OpIgnore;
          p_target_partnum = partnum;
          p_target_start = start; p_target_end = ~^ 64L
        } ]
      )
      else
        []
  in

  let partitions =
    (* Choose the alignment of the first partition based on the
     * '--align-first' option.  Old virt-resize used to always align this
     * to 64 sectors, but this causes boot failures unless we are able to
     * adjust the bootloader accordingly.
     *)
    let start =
      if align_first_partition_and_fix_bootloader then
        alignment
      else
        (* Preserve the existing start, but convert to sectors. *)
        (List.hd partitions).p_part.G.part_start /^ sectsize in

    calculate_target_partitions 1 start ~create_surplus:true partitions in

  let mbr_part_type x =
    match parttype, x.p_part.G.part_num <= 4_l, x.p_type with
    (* for GPT, all partitions are regarded as Primary Partition. *)
    | GPT, _, _ -> "primary"
    | MBR, true, (ContentUnknown|ContentPV _|ContentFS _) -> "primary"
    | MBR, true, ContentExtendedPartition -> "extended"
    | MBR, false, _ -> "logical"
  in

  (* Now partition the target disk. *)
  List.iter (
    fun p ->
      g#part_add "/dev/sdb" (mbr_part_type p) p.p_target_start p.p_target_end
  ) partitions;

  (* Copy over the data. *)
  let copy_partition p =
      match p.p_operation with
      | OpCopy | OpResize _ ->
        (* XXX Old code had 'when target_partnum > 0', but it appears
         * to have served no purpose since the field could never be 0
         * at this point.
         *)

        let oldsize = p.p_part.G.part_size in
        let newsize =
          match p.p_operation with OpResize s -> s | _ -> oldsize in

        let copysize = if newsize < oldsize then newsize else oldsize in

        let source = p.p_name in
        let target = sprintf "/dev/sdb%d" p.p_target_partnum in

        if not quiet then
          printf (f_"Copying %s ...\n%!") source;

        (match p.p_type with
         | ContentUnknown | ContentPV _ | ContentFS _ ->
           g#copy_device_to_device ~size:copysize ~sparse source target

         | ContentExtendedPartition ->
           (* You can't just copy an extended partition by name, eg.
            * source = "/dev/sda2", because the device name only covers
            * the first 1K of the partition.  Instead, copy the
            * source bytes from the parent disk (/dev/sda).
            *
            * You can't write directly to the extended partition,
            * because the size of it reported by Linux is always 1024
            * bytes. Instead, write to the offset of the extended
            * partition in the destination disk (/dev/sdb).
            *)
           let srcoffset = p.p_part.G.part_start in
           let destoffset = p.p_target_start *^ 512L in
           g#copy_device_to_device ~srcoffset ~destoffset ~size:copysize "/dev/sda" "/dev/sdb"
        )
      | OpIgnore | OpDelete -> ()
  in
  List.iter copy_partition partitions;

  (* Set bootable and MBR IDs.  Do this *after* copying over the data,
   * so that we can magically change the primary partition to an extended
   * partition if necessary.
   *)
  let set_partition_bootable_and_id p =
      if p.p_bootable then
        g#part_set_bootable "/dev/sdb" p.p_target_partnum true;

      (match p.p_label with
      | Some label ->
        g#part_set_name "/dev/sdb" p.p_target_partnum label;
      | None -> ()
      );

      (match p.p_guid with
      | Some guid ->
        g#part_set_gpt_guid "/dev/sdb" p.p_target_partnum guid;
      | None -> ()
      );

      match parttype, p.p_id with
      | GPT, GPT_Type gpt_type ->
        g#part_set_gpt_type "/dev/sdb" p.p_target_partnum gpt_type
      | MBR, MBR_ID mbr_id ->
        g#part_set_mbr_id "/dev/sdb" p.p_target_partnum mbr_id
      | GPT, (No_ID|MBR_ID _) | MBR, (No_ID|GPT_Type _) -> ()
  in
  List.iter set_partition_bootable_and_id partitions;

  (* Fix the bootloader if we aligned the first partition. *)
  if align_first_partition_and_fix_bootloader then (
    (* See can_fix_boot_loader above. *)
    match partitions with
    | { p_type = ContentFS ("ntfs", _); p_bootable = true;
        p_target_partnum = partnum; p_target_start = start } :: _ ->
      (* If the first partition is NTFS and bootable, set the "Number of
       * Hidden Sectors" field in the NTFS Boot Record so that the
       * filesystem is still bootable.
       *)

      (* Should always be /dev/sdb1? *)
      let target = sprintf "/dev/sdb%d" partnum in

      (* Sanity check: it contains the NTFS magic. *)
      let magic = g#pread_device target 8 3L in
      if magic <> "NTFS    " then
        warning ~prog (f_"first partition is NTFS but does not contain NTFS boot loader magic")
      else (
        if not quiet then
          printf (f_"Fixing first NTFS partition boot record ...\n%!");

        if verbose then (
          let old_hidden = int_of_le32 (g#pread_device target 4 0x1c_L) in
          eprintf "old hidden sectors value: 0x%Lx\n%!" old_hidden
        );

        let new_hidden = le32_of_int start in
        ignore (g#pwrite_device target new_hidden 0x1c_L)
      )

    | { p_type =
        (ContentFS _|ContentUnknown|ContentPV _
            |ContentExtendedPartition) } :: _
    | [] -> ()
  );

  (* After copying the data over we must shut down and restart the
   * appliance in order to expand the content.  The reason for this may
   * not be obvious, but it's because otherwise we'll have duplicate VGs
   * (the old VG(s) and the new VG(s)) which breaks LVM.
   *
   * The restart is only required if we're going to expand something.
   *)
  let to_be_expanded =
    List.exists (
      function
      | ({ p_operation = OpResize _ } as p) ->
        can_expand_content p.p_type
      | { p_operation = (OpCopy | OpIgnore | OpDelete) } -> false
    ) partitions
    || List.exists (
      function
      | ({ lv_operation = LVOpExpand } as lv) ->
        can_expand_content lv.lv_type
      | { lv_operation = LVOpNone } -> false
    ) lvs in

  let g =
    if to_be_expanded then (
      g#shutdown ();
      g#close ();

      let g = new G.guestfs () in
      if trace then g#set_trace true;
      if verbose then g#set_verbose true;
      (* The output disk is being created, so use cache=unsafe here. *)
      g#add_drive ?format:output_format ~readonly:false ~cachemode:"unsafe"
        outfile;
      if not quiet then Progress.set_up_progress_bar ~machine_readable g;
      g#launch ();

      g (* Return new handle. *)
    )
    else g (* Return existing handle. *) in

  if to_be_expanded then (
    (* Helper function to expand partition or LV content. *)
    let do_expand_content target =
      let with_mounted dev (resize : string -> unit) =
        (* Btrfs and XFS need to mount the filesystem to resize it. *)
        assert (Array.length (g#mounts ()) = 0);
        g#mount dev "/";
        resize "/";
        g#umount "/"
      in
      function
      | PVResize -> g#pvresize target
      | Resize2fs -> g#resize2fs target
      | NTFSResize -> g#ntfsresize ~force:ntfsresize_force target
      | BtrfsFilesystemResize -> with_mounted target g#btrfs_filesystem_resize
      | XFSGrowFS -> with_mounted target g#xfs_growfs
    in

    (* Expand partition content as required. *)
    let expand_partition_content = function
      | ({ p_operation = OpResize _ } as p)
          when can_expand_content p.p_type ->
          let source = p.p_name in
          let target = sprintf "/dev/sda%d" p.p_target_partnum in
          let meth = expand_content_method p.p_type in

          if not quiet then
            printf (f_"Expanding %s%s using the '%s' method ...\n%!")
              source
              (if source <> target then sprintf " (now %s)" target else "")
              (string_of_expand_content_method meth);

          do_expand_content target meth
      | { p_operation = (OpCopy | OpIgnore | OpDelete | OpResize _) }
        -> ()
    in
    List.iter expand_partition_content partitions;

    (* Expand logical volume content as required. *)
    List.iter (
      function
      | ({ lv_operation = LVOpExpand } as lv)
          when can_expand_content lv.lv_type ->
          let name = lv.lv_name in
          let meth = expand_content_method lv.lv_type in

          if not quiet then
            printf (f_"Expanding %s using the '%s' method ...\n%!")
              name
              (string_of_expand_content_method meth);

          (* First expand the LV itself to maximum size. *)
          g#lvresize_free name 100;

          (* Then expand the content in the LV. *)
          do_expand_content name meth
      | { lv_operation = (LVOpExpand | LVOpNone) } -> ()
    ) lvs
  );

  (* Finished.  Unmount disks and exit. *)
  g#shutdown ();
  g#close ();

  (* Because we used cache=unsafe when writing the output file, the
   * file might not be committed to disk.  This is a problem if qemu is
   * immediately used afterwards with cache=none (which uses O_DIRECT
   * and therefore bypasses the host cache).  In general you should not
   * use cache=none.
   *)
  Fsync.file outfile;

  if not quiet then (
    print_newline ();
    wrap (s_"Resize operation completed with no errors.  Before deleting the old disk, carefully check that the resized disk boots and works correctly.\n");
  );

  if debug_gc then
    Gc.compact ()

let () = run_main_and_handle_errors ~prog main
