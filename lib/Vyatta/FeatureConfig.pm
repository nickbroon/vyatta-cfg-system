# Module: FeatureConfig.pm
# Functions to assist with maintenance of configuration for features.
# The module is a simple wrapper over the perl ini file library and
# provides the ability to set/delete/retrieve the values of the specified
# config parameters.

# Copyright (c) 2018-2019 AT&T Intellectual Property.
#    All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only

package Vyatta::FeatureConfig;
use strict;
use warnings;
use Config::IniFiles;

require Exporter;

our @ISA       = qw (Exporter);
our @EXPORT_OK = qw(setup_cfg_file set_cfg del_cfg get_cfg
 get_default_cfg get_cfg_file get_cfg_value get_default_cfg_value);

my $DEFAULT_SEC_NAME = "Defaults";

sub setup_cfg_file {
    my ( $mod_name, $cfg_file, $main_section ) = @_;
    my ( $fh, $datestr );

    my $success = open( $fh, "+>", $cfg_file );
    die "Could not open config file $cfg_file" unless $success;
    my $cfg = Config::IniFiles->new(
        -file          => $fh,
        -allowcontinue => 1,
        -allowempty    => 1
    );
    die
"Could not create ini instance for $cfg_file : @Config::IniFiles::errors\n"
      unless defined($cfg);

    $cfg->AddSection($main_section);
    $datestr = localtime();
    $cfg->SetSectionComment( $main_section,
            "# $cfg_file \n"
          . "# Auto-generated by $mod_name.\n"
          . "# Generation Time: $datestr \n"
          . "# Do not edit." );
    $cfg->AddSection($DEFAULT_SEC_NAME);
    $cfg->WriteConfig($cfg_file);
    close($fh);
}

sub set_cfg {
    my ( $cfg_file, $section, $var, $value, $default ) = @_;
    my ( $fh, $success );

    $success = open( $fh, "+<", $cfg_file );
    die "Could not open config file $cfg_file" unless $success;

    my $cfg = Config::IniFiles->new(
        -file          => $fh,
        -default       => $DEFAULT_SEC_NAME,
        -allowcontinue => 1,
        -allowempty    => 1
    );
    die
"Could not create ini instance for $cfg_file : @Config::IniFiles::errors\n"
      unless defined($cfg);

    if ( defined($default) && $default ) {
        $section = $DEFAULT_SEC_NAME;
    }
    if ( $cfg->exists( $section, $var ) ) {
        $cfg->setval( $section, $var, $value );
    } else {
        $cfg->newval( $section, $var, $value );
    }
    $cfg->RewriteConfig();
    close($fh);
}

sub del_cfg {
    my ( $cfg_file, $section, $var, $value, $default ) = @_;
    my $fh;

    open( $fh, "+<", $cfg_file )
      || die "Could not open config file $cfg_file";

    my $cfg = Config::IniFiles->new(
        -file          => $fh,
        -default       => $DEFAULT_SEC_NAME,
        -allowcontinue => 1
    );
    die
"Could not create ini instance for $cfg_file : @Config::IniFiles::errors\n"
      unless defined($cfg);

    if ( defined($default) && $default ) {
        $section = $DEFAULT_SEC_NAME;
    }
    $cfg->delval( $section, $var );
    $cfg->RewriteConfig();
    close($fh);
}

# Allows for scripts that want to access the config file multiple times to
# open it once, read multiple times, then close once.  Greatly reduces overall
# time taken.
#
# NB: function returns $cfg (IniFile object for reading) and $fh.  Caller's
#     responsibility to close $fh when done.
sub get_cfg_file {
	my $cfg_file = shift;
	my $fh;

    open( $fh, "<", $cfg_file )
		|| return;

    my $cfg = Config::IniFiles->new(
        -file          => $fh,
        -allowcontinue => 1
		);
	return unless defined($cfg);

	return ( $cfg, $fh );
}

sub get_cfg_value {
	my ( $cfg, $section, $var ) = @_;

	return unless defined($cfg);
	return $cfg->val( $section, $var );
}

# Highly inefficient for scripts that make multiple calls as it opens and
# closes the same file on each call.  Use get_cfg_file / get_cfg_value for
# preference.
sub get_cfg {
    my ( $cfg_file, $section, $var ) = @_;
    my ( $value, $fh );

    open( $fh, "<", $cfg_file )
      || die "Could not open config file $cfg_file";

    my $cfg = Config::IniFiles->new(
        -file          => $fh,
        -allowcontinue => 1
    );
    die
"Could not create ini file instance for $cfg_file : @Config::IniFiles::errors\n"
      unless defined($cfg);

    $value = $cfg->val( $section, $var );
    close($fh);

    return ( $value );
}

sub get_default_cfg {
    my ( $cfg_file, $var ) = @_;

	return get_cfg($cfg_file, $DEFAULT_SEC_NAME, $var);
}

# More efficient than get_default_cfg as it reads from an already opened
# file ($cfg) rather than opening it afresh each time.
sub get_default_cfg_value {
    my ( $cfg, $var ) = @_;

	return get_cfg_value($cfg, $DEFAULT_SEC_NAME, $var);
}
