# *************************************************************************
#
# Copyright 2020 Xilinx, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# *************************************************************************
proc _do_impl {jobs {strategies ""}} {
    if {![llength $strategies]} {
        launch_runs impl_1 -to_step write_bitstream -jobs $jobs
        wait_on_run impl_1
    } else {
        set impl_runs "impl_1"
        set_property STRATEGY "[lindex $strategies 0]" [get_runs impl_1]
        for {set i 1} {$i < [llength $strategies]} {incr i 1} {
            set r impl_[expr $i + 1]
            set s [lindex $strategies $i]
            create_run $r -flow {Vivado Implementation 2020} -parent_run synth_1 -strategy "$s"
            lappend impl_runs $r
        }
        launch_runs $impl_runs -to_step write_bitstream -jobs $jobs
        foreach r $impl_runs {
            wait_on_run $r
        }
    }
}

# Check the QDMA IP instances among the IPs in `ips` (those that exist in the
# current project).  With a requested version, exit on a different version or
# on a locked IP (created by another Vivado release).  Returns a list of
# {ip vlnv locked xci}.
proc _check_qdma_ips {ips requested context} {
    set found {}
    foreach ip $ips {
        set obj [get_ips -quiet $ip]
        if {[string equal $obj ""]} {
            continue
        }
        set vlnv [get_property IPDEF $obj]
        if {![string match "xilinx.com:ip:qdma:*" $vlnv]} {
            continue
        }
        set ver [lindex [split $vlnv :] end]
        set locked [get_property IS_LOCKED $obj]
        set xci [get_property IP_FILE $obj]
        lappend found [list $ip $vlnv $locked $xci]
        set note [expr {$locked ? " (locked: created by another Vivado release)" : ""}]
        puts "INFO: \[QDMA\] $context: $ip is ${vlnv}${note}"
        if {[string equal $requested ""]} {
            if {$locked} {
                puts "WARNING: \[QDMA\] $context: $ip is locked, its output products are from another Vivado release; use a new -tag or -overwrite 1"
            }
            if {[package vcompare $ver 5.0] >= 0} {
                puts "WARNING: \[QDMA\] QDMA $ver requires a host driver with QDMA 5.0 support"
            }
            continue
        }
        if {![string equal $ver $requested]} {
            puts "ERROR: \[QDMA\] $context: -qdma_ip_version $requested requested, but $ip is $vlnv ($xci); use a new -tag or -overwrite 1"
            exit 1
        }
        if {$locked} {
            puts "ERROR: \[QDMA\] $context: $ip is locked (created by another Vivado release); use a new -tag or -overwrite 1"
            exit 1
        }
    }
    if {[llength $found] == 0 && ![string equal $requested ""]} {
        puts "ERROR: \[QDMA\] $context: no xilinx.com:ip:qdma instance found"
        exit 1
    }
    return $found
}

# Names of the IPs in the current project
proc _ip_names {} {
    set names {}
    foreach ip [get_ips -quiet] {
        lappend names [get_property NAME $ip]
    }
    return $names
}

# Write QDMA_IP_VERSION from the check of the project that is (or would be)
# implemented: first line the QDMA VLNV, then the Vivado version and one line
# per QDMA instance.  `cache` is the result for the IP build directory.
proc _record_qdma_ips {path found cache} {
    if {[llength $found] == 0} {
        puts "WARNING: \[QDMA\] no QDMA IP in the design project; $path not written"
        return
    }
    set used {}
    set cached {}
    foreach q $found {
        lappend used [lindex $q 1]
    }
    foreach q $cache {
        lappend cached [lindex $q 1]
    }
    set used [lsort -unique $used]
    set cached [lsort -unique $cached]
    if {![string equal $used $cached]} {
        puts "WARNING: \[QDMA\] the design project uses $used, the IP build directory has $cached"
    }
    set fp [open $path w]
    puts $fp [lindex [lindex $found 0] 1]
    puts $fp "vivado [version -short]"
    foreach q $found {
        lassign $q q_ip q_vlnv q_locked q_xci
        puts $fp "ip $q_ip $q_vlnv locked=$q_locked $q_xci"
    }
    close $fp
}

proc _do_post_impl {build_dir top impl_run {zynq_family 0} board} {
    if {$zynq_family} {
        current_run $impl_run
        set sdk_dir ${build_dir}/${top}.sdk
        file mkdir $sdk_dir
        write_hw_platform -fixed -force -include_bit -file ${sdk_dir}/${top}.xsa
    } else {
        if {$board == "au45n"} {
            set mem_size 256
            set start_address 0x00000000
        } else {
            set mem_size 128
            set start_address 0x01002000
        }
        set interface SPIx4
        set bit_file ${build_dir}/${top}.runs/${impl_run}/${top}.bit
        set mcs_file ${build_dir}/${top}.runs/${impl_run}/${top}.mcs
        write_cfgmem -format mcs -size $mem_size -interface $interface -loadbit "up $start_address $bit_file" -file "$mcs_file"
    }
}

# Directory variables
set root_dir [file normalize ..]
set constr_dir ${root_dir}/constr
set plugin_dir ${root_dir}/plugin
set script_dir ${root_dir}/script
set src_dir ${root_dir}/src

# Build options
#   board_repo             Path to the Xilinx board store repository
#   board                  Board name
#   tag                    Tag to identify the build
#   overwrite              Overwrite existing build results
#   rebuild                Update build directory but respect overwrite
#   jobs                   Number of jobs for synthesis and implementation
#   synth_ip               Synthesize IPs before creating design project
#   impl                   Run implementation after creating design project
#   post_impl              Perform post implementation actions
#   user_plugin            Path to the user plugin repo
#   bitstream_userid       Bitstream.config userid
#   bitstream_usr_access   Bitstream.config usr_access
#   sim                    Build design for simulation
#   qdma_ip_version        Expected QDMA IP version (e.g. 4.0 or 5.0); empty
#                          accepts whatever this Vivado release provides
#
# Design parameters
#   build_timestamp  Timestamp to identify the build
#   min_pkt_len      Minimum packet length
#   max_pkt_len      Maximum packet length
#   use_phys_func    Include H2C and C2H AXI-stream interfaces (0 or 1)
#   num_phys_func    Number of PCI-e physical functions (1 to 4)
#   num_qdma      Number of QDMA interfaces (1 to 2)
#   num_queue        Number of QDMA queues (1 to 2048)
#   num_cmac_port    Number of CMAC ports (1 or 2)
#
# Simulation parameters
#   sim_exec_path  Path to directory containing simulator executable
#   sim_lib_path   Path where simulation libraries should be compiled
#   sim_top        Top level module to simulate

array set build_options {
    -board_repo  ""
    -board       au250
    -tag         ""
    -overwrite   0
    -rebuild     0
    -jobs        8
    -synth_ip    1
    -impl        0
    -post_impl   0
    -user_plugin ""
    -bitstream_userid  "0xDEADC0DE"
    -bitstream_usr_access "0x66669999"
    -sim  0
    -qdma_ip_version ""
}
set build_options(-user_plugin) ${plugin_dir}/p2p

array set design_params {
    -build_timestamp  0
    -min_pkt_len      64
    -max_pkt_len      1518
    -use_phys_func    1
    -num_phys_func    1
    -num_qdma         1
    -num_queue        512
    -num_cmac_port    1
}
set design_params(-build_timestamp) [clock format [clock seconds] -format %m%d%H%M]

array set sim_params {
    -sim_exec_path    ""
    -sim_lib_path     ""
    -sim_top          ""
}

# Expect arguments in the form of `-argument value`
for {set i 0} {$i < $argc} {incr i 2} {
    set arg [lindex $argv $i]
    set val [lindex $argv [expr $i+1]]
    if {[info exists build_options($arg)]} {
        set build_options($arg) $val
        puts "Set build option $arg to $val"
    } elseif {[info exists design_params($arg)]} {
        set design_params($arg) $val
        puts "Set design parameter $arg to $val"
    } elseif {[info exists sim_params($arg)]} {
        set sim_params($arg) $val
        puts "Set sim parameter $arg to $val"
    } else {
        puts "Skip unknown argument $arg and its value $val"
    }
}

# Settings based on defaults or passed in values
foreach {key value} [array get build_options] {
    set [string range $key 1 end] $value
}
foreach {key value} [array get design_params] {
    set [string range $key 1 end] $value
}

# Sanity check
if {$min_pkt_len < 64 || $min_pkt_len > 256} {
    puts "Invalid value for -min_pkt_len: allowed range is \[64, 256\]"
    exit
}
if {$max_pkt_len < 256 || $max_pkt_len > 9600} {
    puts "Invalid value for -max_pkt_len: allowed range is \[256, 9600\]"
    exit
}
if {$use_phys_func == 1} {
    if {$num_queue < 1 || $num_queue > 2048} {
        puts "Invalid value for -num_queue: allowed range is \[1, 2048\]"
        exit
    }
    if {$num_phys_func < 1 || $num_phys_func > 4} {
        puts "Invalid value for -num_phys_func: allowed range is \[1, 4\]"
        exit
    }
    if {$num_qdma < 1 || $num_qdma > 2} {
        puts "Invalid value for -num_qdma: allowed range is \[1, 2\]"
        exit
    }
}
if {$num_cmac_port != 1 && $num_cmac_port != 2} {
    puts "Invalid value for -num_cmac_port: allowed values are 1 and 2"
    exit
}

source ${script_dir}/board_settings/${board}.tcl

# Set build directory and dump the current design parameters
set top open_nic_shell
set build_name ${board}
if {![string equal $tag ""]} {
    set build_name ${build_name}_${tag}
}

set build_dir [file normalize ${root_dir}/build/${build_name}]
if {[file exists $build_dir]} {
    if {!$rebuild } {
        puts "Found existing build directory $build_dir"
        puts "  1. Update existing build directory (default)"
        puts "  2. Delete existing build directory and create a new one"
        puts "  3. Exit"
        puts -nonewline {Choose an option: }
        gets stdin ans
        if {[string equal $ans "2"]} {
            file delete -force $build_dir
            puts "Deleted existing build directory $build_dir"
            file mkdir $build_dir
        } elseif {[string equal $ans "3"]} {
            puts "Build directory existed. Try to specify a different design tag"
            exit
        }
    } else {
	file delete -force $build_dir/open_nic_shell
	puts "Deleted existing build director $build_dir/open_nic_shell"
    }
} else {
    file mkdir $build_dir
}
set fp [open "${build_dir}/DESIGN_PARAMETERS" w]
foreach {param val} [array get design_params] {
    puts $fp "$param $val"
}
close $fp

# Update the board store
if {[string equal $board_repo ""]} {
    set_param board.repoPaths "${root_dir}/board_files"    
    # xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
} else {
    set_param board.repoPaths $board_repo
}

# Enumerate modules
foreach name [glob -tails -directory ${src_dir} -type d *] {
    if {![string equal $name "shell"]} {
        dict append module_dict $name "${src_dir}/${name}"
    }
}

# Create/open Manage IP project
set ip_build_dir ${build_dir}/vivado_ip
if {![file exists ${ip_build_dir}/manage_ip/]} {
    puts "INFO: \[Manage IP\] Creating Manage IP project..."
    create_project -force manage_ip ${ip_build_dir}/manage_ip -part $part -ip
    if {![string equal $board_part ""]} {
        set_property BOARD_PART $board_part [current_project]
    }
    set_property simulator_language verilog [current_project]
} else {
    puts "INFO: \[Manage IP\] Opening existing Manage IP project..."
    open_project -quiet ${ip_build_dir}/manage_ip/manage_ip.xpr
}

# Resolve the QDMA IP version.  This needs the IP catalog, hence an open
# project.  The vivado_ip scripts call create_ip without -version, so each
# Vivado release silently picks its only QDMA version: 4.0 up to Vivado
# 2022.1, 5.0 from Vivado 2022.2.  QDMA 5.0 needs a driver with QDMA 5.0
# support, so record the version and optionally enforce it.
#
# The catalog only tells what a new IP would be.  An IP reused from an
# existing build directory keeps the version it was created with, and an
# existing design project can reference other IP than that directory holds.
# So the instances are checked after the IP step and again in the design
# project, and QDMA_IP_VERSION is written from the design project only.  A
# stale record is removed first.
file delete -force ${build_dir}/QDMA_IP_VERSION
set qdma_ipdefs [lsort -dictionary [get_ipdefs -quiet xilinx.com:ip:qdma:*]]
if {[llength $qdma_ipdefs] == 0} {
    puts "ERROR: \[QDMA\] No xilinx.com:ip:qdma IP found in this Vivado installation"
    exit 1
}
set qdma_vlnv [lindex $qdma_ipdefs end]
puts "INFO: \[QDMA\] Vivado [version -short] IP catalog provides $qdma_vlnv"
if {![string equal $qdma_ip_version ""] &&
    [lsearch -exact $qdma_ipdefs xilinx.com:ip:qdma:$qdma_ip_version] < 0} {
    puts "ERROR: \[QDMA\] -qdma_ip_version $qdma_ip_version requested, but this Vivado provides $qdma_vlnv"
    exit 1
}

# Run synthesis for each IP
set ip_dict [dict create]
dict for {module module_dir} $module_dict {
    set ip_tcl_dir ${module_dir}/vivado_ip

    # Check the existence of "$ip_tcl_dir" and "${ip_tcl_dir}/vivado_ip.tcl"
    if {![file exists $ip_tcl_dir] || ![file exists ${ip_tcl_dir}/vivado_ip.tcl]} {
        puts "INFO: \[$module\] Nothing to build"
        continue
    }

    # Expect the variable "$ips" defined in "vivado_ip.tcl"
    source ${ip_tcl_dir}/vivado_ip.tcl
    if {![info exists ips]} {
        puts "INFO: \[$module\] Nothing to build"
        continue
    }

    foreach ip $ips {
        # Pre-save IP name and its build directory to a global dictionary
        dict append ip_dict $ip ${ip_build_dir}/${ip}

        # Remove IP that does not exists in the project, which may have been
        # deleted by the user and needs to be regnerated
        if {[string equal [get_ips -quiet $ip] ""]} {
            export_ip_user_files -of_objects [get_files ${ip_build_dir}/${ip}/${ip}.xci] -no_script -reset -force -quiet
            remove_files -quiet [get_files ${ip_build_dir}/${ip}/${ip}.xci]
            file delete -force ${ip_build_dir}/${ip}
        }

        # Build the IPs only when
        # - IP directory does not exist, or
        # - "$overwrite" option is nonzero
        set cached [file exists ${ip_build_dir}/${ip}]
        if {$cached && !$overwrite} {
            puts "INFO: \[$ip\] Use existing IP build (overwrite=0)"
            continue
        }
        if {$cached} {
            puts "INFO: \[$ip\] Found existing IP build, deleting... (overwrite=1)"
            file delete -force ${ip_build_dir}/${ip}
        }

        # Rule for IP scripts
        # - Source "${ip}_${board}.tcl" if exists
        # - Else, source "${ip}.tcl" if exists
        # - Otherwise, skip this IP as it may be specific for certain board target
        if {[file exists "${ip_tcl_dir}/${ip}_${board}.tcl"]} {
            source ${ip_tcl_dir}/${ip}_${board}.tcl
        } elseif {[file exists "${ip_tcl_dir}/${ip}.tcl"]} {
            source ${ip_tcl_dir}/${ip}.tcl
        } else {
            continue
        }

        upgrade_ip [get_ips $ip]
        generate_target synthesis [get_ips $ip]

        # Run out-of-context IP synthesis
        if {$synth_ip} {
            create_ip_run [get_ips $ip]
            launch_runs ${ip}_synth_1
            wait_on_run ${ip}_synth_1
        }
    }
}

# Check the QDMA IP in the IP build directory (created now or reused)
set qdma_cache [_check_qdma_ips [dict keys $ip_dict] $qdma_ip_version "IP build"]

# Close the Manage IP project
close_project

# Setup build directory for the design
set top_build_dir ${build_dir}/${top}

if {[file exists $top_build_dir] && !$overwrite} {
    puts "INFO: \[$top\] Use existing build (overwrite=0)"
    # That project decides what an implementation contains; check its IP
    open_project -read_only ${top_build_dir}/${top}.xpr
    set qdma_used [_check_qdma_ips [_ip_names] $qdma_ip_version "project $top"]
    close_project
    _record_qdma_ips ${build_dir}/QDMA_IP_VERSION $qdma_used $qdma_cache
    if {$impl || $post_impl || $sim} {
        puts "WARNING: \[$top\] existing project reused, nothing else is run (-impl, -post_impl and -sim are ignored); use a new -tag or -overwrite 1"
    }
    return
}
if {[file exists $top_build_dir]} {
    puts "INFO: \[$top\] Found existing build, deleting... (overwrite=1)"
    file delete -force $top_build_dir
}

create_project -force $top $top_build_dir -part $part
if {![string equal $board_part ""]} {
    set_property BOARD_PART $board_part [current_project]
}
set_property target_language verilog [current_project]

# Marco to enable conditional compilation at Verilog level
set verilog_define "__synthesis__ __${board}__"
if {$zynq_family} {
    append verilog_define " " "__zynq_family__"
}
set_property verilog_define $verilog_define [current_fileset]

# Read IPs from finished IP runs
# - Some IPs are board-specific and will be ignored for other board targets
dict for {ip ip_dir} $ip_dict {
    read_ip -quiet ${ip_dir}/${ip}.xci
}
set qdma_used [_check_qdma_ips [_ip_names] $qdma_ip_version "project $top"]
_record_qdma_ips ${build_dir}/QDMA_IP_VERSION $qdma_used $qdma_cache

# Read user plugin files
set include_dirs [get_property include_dirs [current_fileset]]
foreach freq [list 250mhz 322mhz] {
    set box "box_$freq"
    set box_plugin ${user_plugin}/${box}
    
    if {![file exists $box_plugin] || ![file exists ${user_plugin}/build_${box}.tcl]} {
        set box_plugin ${plugin_dir}/p2p/${box}
    }

    source ${box_plugin}/${box}_axi_crossbar.tcl
    read_verilog -quiet ${box_plugin}/${box}_address_map.v
    lappend include_dirs $box_plugin

    if {![file exists ${user_plugin}/build_${box}.tcl]} {
        cd ${plugin_dir}/p2p
        source build_${box}.tcl
    } else {
        cd $user_plugin
        source build_${box}.tcl
    }
    cd $script_dir
}
set_property include_dirs $include_dirs [current_fileset]

# Read the source files from each module
# - First, source "build.tcl" if it is defined under `module_dir`
# - Then, read all the RTL files under `module_dir` (excluding sub-directories)
dict for {module module_dir} $module_dict {
    if {[file exists ${module_dir}/build.tcl]} {
        cd $module_dir
        source build.tcl
        cd $script_dir
    }

    read_verilog -quiet [glob -nocomplain -directory $module_dir "*.{v,vh}"]
    read_verilog -quiet -sv [glob -nocomplain -directory $module_dir "*.sv"]
    read_vhdl -quiet [glob -nocomplain -directory $module_dir "*.vhd"]
}

# Read top-level source files
read_verilog -quiet [glob -nocomplain -directory $src_dir "*.{v,vh}"]
read_verilog -quiet -sv [glob -nocomplain -directory $src_dir "*.sv"]
read_vhdl -quiet [glob -nocomplain -directory $src_dir "*.vhd"]

# Set vivado generic
set design_params(-build_timestamp) "32'h$design_params(-build_timestamp)"
set generic ""
foreach {key value} [array get design_params] {
    set p [string toupper [string range $key 1 end]]
    lappend generic "$p=$value"
}
set_property -name generic -value $generic -object [current_fileset]
set_property top $top [get_property srcset [current_run]]

puts "bitstream_userid is $bitstream_userid"
puts "bitstream_usr_acceess is $bitstream_usr_access"

# generate the xdc with the run specific parameters dynamically
set fp [open "${build_dir}/run_params.xdc" w]
puts $fp "set_property BITSTREAM.CONFIG.USERID \"$bitstream_userid\" \[current_design\]"
puts $fp "set_property BITSTREAM.CONFIG.USR_ACCESS $bitstream_usr_access \[current_design\]"
close $fp

# Read constraint files
read_xdc -unmanaged ${constr_dir}/${board}/pins.xdc
read_xdc -unmanaged ${constr_dir}/${board}/timing.xdc
read_xdc ${constr_dir}/${board}/general.xdc
read_xdc ${build_dir}/run_params.xdc

# Simulate design
if {$sim} {
    # Generate simulation libraries
    set modelsim_lib_path ${sim_params(-sim_lib_path)}/modelsim
    if {[file exists ${modelsim_lib_path}]} {
        puts "Skipping compilation of simulation libraries as directory ${modelsim_lib_path} exists."
    } else {
        puts "Compiling simulation libraries in directory ${modelsim_lib_path}."
        compile_simlib -simulator modelsim -simulator_exec_path ${sim_params(-sim_exec_path)} \
            -family all -language all -library all \
            -dir ${modelsim_lib_path}
    }

    # Export simulation
    set_property target_simulator ModelSim [current_project]
    set_property top $sim_params(-sim_top) [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    set_property compxlib.modelsim_compiled_library_dir ${modelsim_lib_path} [current_project]
    launch_simulation -scripts_only
}

# Implement design
if {$impl} {
    update_compile_order -fileset sources_1
    _do_impl $jobs {"Vivado Implementation Defaults"}
}

if {$post_impl} {
    _do_post_impl $top_build_dir $top impl_1 $zynq_family ${board}
}
