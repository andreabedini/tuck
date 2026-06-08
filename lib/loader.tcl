namespace eval ::tuck::phase {}
namespace eval ::tuck::interp {
    variable target ""
    variable rules  ""
}

# Reset all mutable state — used between test cases and at process start.
proc ::tuck::reset {} {
    set ::tuck::graph::rules {}
    set ::tuck::graph::targets {}
    set ::tuck::_current_pkg ""
    set ::tuck::graph::artifacts {}
    set ::tuck::graph::actions {}
    set ::tuck::graph::target_outputs {}
    set ::tuck::graph::_action_counter {}
    if {$::tuck::interp::target ne "" && [interp exists $::tuck::interp::target]} {
        interp delete $::tuck::interp::target
    }
    if {$::tuck::interp::rules ne "" && [interp exists $::tuck::interp::rules]} {
        interp delete $::tuck::interp::rules
    }
    set ::tuck::interp::target ""
    set ::tuck::interp::rules ""
}

# Create the shared, persistent target and rules interpreters.
proc ::tuck::phase::setup {} {
    # `-safe` strips open/exec/file/package so these children cannot touch disk;
    # aliases are the only escape hatch. See docs/CODE-TOUR.md §2 and §4.1.
    set ::tuck::interp::target [interp create -safe]
    set ::tuck::interp::rules  [interp create -safe]
    $::tuck::interp::rules alias tuck::rule ::tuck::register_rule
    ::tuck::ctx::install $::tuck::interp::rules
}

# Install a rule constructor (named $name) into the shared target interp.
# Called by ::tuck::register_rule.
proc ::tuck::_install_ctor {name} {
    $::tuck::interp::target alias $name ::tuck::register_target $name
}

# Read a file from disk (root interp only) and return its contents.
proc ::tuck::phase::_slurp {path} {
    set fh [open $path r]
    try {
        return [read $fh]
    } finally {
        close $fh
    }
}

# Evaluate one BUILD/TUCK file for package $pkg inside a fresh loader interp.
proc ::tuck::phase::load_file {path pkg} {
    set ::tuck::_current_pkg $pkg
    set src [::tuck::phase::_slurp $path]
    set loader [interp create -safe]
    $loader alias targets ::tuck::phase::_eval_targets
    $loader alias rules   ::tuck::phase::_eval_rules
    try {
        $loader eval $src
    } finally {
        interp delete $loader
    }
}

proc ::tuck::phase::_eval_targets {body} {
    $::tuck::interp::target eval $body
}
proc ::tuck::phase::_eval_rules {body} {
    $::tuck::interp::rules eval $body
}

# Load the root TUCK file (rules only), if present. Deterministic, first.
proc ::tuck::phase::load_root_rules {} {
    set tuckfile [file join $::tuck::config::root TUCK]
    if {[file exists $tuckfile]} {
        ::tuck::phase::load_file $tuckfile ""
    }
}

# Load a single package's BUILD file.
proc ::tuck::phase::load_package {pkg} {
    set bf [file join $::tuck::config::root $pkg BUILD]
    if {![file exists $bf]} {
        error "tuck: no BUILD file for package //$pkg"
    }
    ::tuck::phase::load_file $bf $pkg
}

# Lazily load $seed_pkgs and the transitive closure of their dep packages.
proc ::tuck::phase::load_closure {seed_pkgs} {
    set loaded {}
    set pending $seed_pkgs
    while {[llength $pending]} {
        set pkg [lindex $pending 0]
        set pending [lrange $pending 1 end]
        if {[dict exists $loaded $pkg]} continue
        dict set loaded $pkg 1
        ::tuck::phase::load_package $pkg
        dict for {label node} $::tuck::graph::targets {
            foreach dep [dict get $node deps] {
                set dpkg [dict get [::tuck::util::label_parse $dep] pkg]
                if {![dict exists $loaded $dpkg]} {
                    lappend pending $dpkg
                }
            }
        }
    }
}
