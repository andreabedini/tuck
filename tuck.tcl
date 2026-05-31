#!/usr/bin/env tclsh
namespace eval ::tuck {}
set ::tuck::_libdir [file join [file dirname [file normalize [info script]]] lib]
foreach m {config label rules target graph action ctx analyse loader} {
    source [file join $::tuck::_libdir $m.tcl]
}

namespace eval ::tuck::cmd {}

proc ::tuck::cmd::query_deps {label} {
    set canon [::tuck::util::canon $label ""]
    set pkg   [dict get [::tuck::util::label_parse $canon] pkg]
    ::tuck::phase::load_closure [list $pkg]
    ::tuck::graph::validate
    if {![dict exists $::tuck::graph::targets $canon]} {
        error "tuck: no such target: $canon"
    }
    foreach l [::tuck::graph::topo_sort [list $canon]] {
        puts $l
    }
}

proc ::tuck::cmd::_print_action {id} {
    set a [dict get $::tuck::graph::actions $id]
    puts [dict get $a id]
    puts "  inputs:  [dict get $a inputs]"
    puts "  outputs: [dict get $a outputs]"
    puts "  cmd:     [dict get $a cmd]"
}

proc ::tuck::cmd::analyze {label} {
    ::tuck::phase::analyse [list $label]
    foreach id [dict keys $::tuck::graph::actions] {
        ::tuck::cmd::_print_action $id
    }
}

proc ::tuck::cmd::query_actions {label} {
    set canon [::tuck::util::canon $label ""]
    ::tuck::phase::analyse [list $canon]
    foreach id [dict keys $::tuck::graph::actions] {
        if {[dict get $::tuck::graph::actions $id target] eq $canon} {
            ::tuck::cmd::_print_action $id
        }
    }
}

# Find every package (dir containing BUILD) at or under $subdir, relative to root.
proc ::tuck::cmd::_scan_packages {subdir} {
    set base [file join $::tuck::config::root $subdir]
    set pkgs {}
    foreach bf [::tuck::cmd::_find_builds $base] {
        set rel [::tuck::cmd::_relpath $::tuck::config::root [file dirname $bf]]
        lappend pkgs $rel
    }
    return $pkgs
}

proc ::tuck::cmd::_find_builds {dir} {
    set found {}
    if {[file exists [file join $dir BUILD]]} {
        lappend found [file join $dir BUILD]
    }
    foreach sub [glob -nocomplain -types d -directory $dir *] {
        if {[file tail $sub] eq ".tuck"} continue
        lappend found {*}[::tuck::cmd::_find_builds $sub]
    }
    return $found
}

proc ::tuck::cmd::_relpath {root path} {
    set r [file split [file normalize $root]]
    set p [file split [file normalize $path]]
    set tail [lrange $p [llength $r] end]
    return [join $tail /]
}

proc ::tuck::cmd::targets {pattern} {
    if {$pattern eq "//..." || [string match "*/..." $pattern]} {
        set sub [string range $pattern 2 end]      ;# strip //
        set sub [string range $sub 0 end-3]        ;# strip "..."
        set sub [string trimright $sub /]          ;# strip trailing /
        set pkgs [::tuck::cmd::_scan_packages $sub]
        foreach pkg $pkgs { ::tuck::phase::load_package $pkg }
        ::tuck::graph::validate
        ::tuck::cmd::_print_all
    } elseif {[string match "*:..." $pattern]} {
        set pkg [string range $pattern 2 end-4]    ;# strip // and ":..."
        ::tuck::phase::load_package $pkg
        ::tuck::cmd::_print_pkg $pkg
    } else {
        set canon [::tuck::util::canon $pattern ""]
        set pkg [dict get [::tuck::util::label_parse $canon] pkg]
        ::tuck::phase::load_package $pkg
        if {![dict exists $::tuck::graph::targets $canon]} {
            error "tuck: no such target: $canon"
        }
        puts $canon
    }
}

proc ::tuck::cmd::_print_all {} {
    foreach l [lsort [dict keys $::tuck::graph::targets]] { puts $l }
}

proc ::tuck::cmd::_print_pkg {pkg} {
    set out {}
    dict for {l node} $::tuck::graph::targets {
        if {[dict get $node package] eq $pkg} { lappend out $l }
    }
    foreach l [lsort $out] { puts $l }
}

proc ::tuck::main {argv} {
    ::tuck::reset
    ::tuck::config::init [pwd]
    ::tuck::phase::setup
    ::tuck::phase::load_root_rules
    set cmd [lindex $argv 0]
    switch -- $cmd {
        targets { ::tuck::cmd::targets [lindex $argv 1] }
        analyze { ::tuck::cmd::analyze [lindex $argv 1] }
        query {
            set sub [lindex $argv 1]
            switch -- $sub {
                deps    { ::tuck::cmd::query_deps    [lindex $argv 2] }
                actions { ::tuck::cmd::query_actions [lindex $argv 2] }
                default { error "tuck: unknown query subcommand: $sub" }
            }
        }
        default { error "tuck: unknown command: $cmd" }
    }
}

if {[catch {::tuck::main $argv} err]} {
    puts stderr $err
    exit 1
}
