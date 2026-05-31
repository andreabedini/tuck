namespace eval ::tuck {}
namespace eval ::tuck::graph {
    variable rules {}
}

# Type check for a single attr value. Minimal for M1.
proc ::tuck::check_type {type value rule attr} {
    switch -- $type {
        int {
            if {![string is integer -strict $value]} {
                error "tuck: $rule: attribute '$attr' expected int, got '$value'"
            }
        }
        bool {
            if {![string is boolean -strict $value]} {
                error "tuck: $rule: attribute '$attr' expected bool, got '$value'"
            }
        }
        string - list - sources - dep - deps - output {
            # accepted as-is in M1
        }
        default {
            error "tuck: $rule: attribute '$attr' has unknown type '$type'"
        }
    }
}

# Validate an attrs dict against a schema. Returns the validated dict with
# defaults applied. Errors on missing-mandatory, unknown-attr, bad-type.
proc ::tuck::validate_attrs {rule schema attrs} {
    set out {}
    dict for {attr def} $schema {
        set mandatory [expr {[dict exists $def mandatory] && [dict get $def mandatory]}]
        if {[dict exists $attrs $attr]} {
            set val [dict get $attrs $attr]
            ::tuck::check_type [dict get $def type] $val $rule $attr
            dict set out $attr $val
        } elseif {$mandatory} {
            error "tuck: $rule: missing mandatory attribute '$attr'"
        } elseif {[dict exists $def default]} {
            dict set out $attr [dict get $def default]
        }
    }
    dict for {k _} $attrs {
        if {![dict exists $schema $k]} {
            error "tuck: $rule: unknown attribute '$k'"
        }
    }
    return $out
}

# Register a rule: store its schema, compile its inline impl body into a named
# proc in the rules interp, and install its constructor.
#
# The impl is written inline as a script body taking an implicit `ctx`:
#     tuck::rule genrule { attrs {...} impl { ...uses $ctx... } }
# It is compiled to proc __tuck_impl_<name> {ctx} <body> in the rules interp,
# so analysis always invokes a real named proc (good stack traces) while the
# author writes the ergonomic inline form. Helpers may be defined separately in
# the rules block and called from the body.
proc ::tuck::register_rule {name body} {
    set schema [dict get $body attrs]
    set impl ""
    if {[dict exists $body impl]} {
        set impl __tuck_impl_$name
        $::tuck::interp::rules eval [list proc $impl {ctx} [dict get $body impl]]
    }
    dict set ::tuck::graph::rules $name [dict create schema $schema impl $impl]
    ::tuck::_install_ctor $name
}
