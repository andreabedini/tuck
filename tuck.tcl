#!/usr/bin/env tclsh
namespace eval ::tuck {}
set ::tuck::_libdir [file join [file dirname [file normalize [info script]]] lib]
foreach m {config label rules target graph loader} {
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

proc ::tuck::main {argv} {
    ::tuck::reset
    ::tuck::config::init [pwd]
    ::tuck::phase::setup
    ::tuck::phase::load_root_rules
    set cmd [lindex $argv 0]
    switch -- $cmd {
        query {
            set sub [lindex $argv 1]
            switch -- $sub {
                deps { ::tuck::cmd::query_deps [lindex $argv 2] }
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
