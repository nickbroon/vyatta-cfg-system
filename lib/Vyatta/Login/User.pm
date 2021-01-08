# **** License ****
# Copyright (c) 2018-2020, AT&T Intellectual Property.
# All Rights Reserved.
#
# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****

package Vyatta::Login::User;
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use JSON;
use IPC::Run3;

use constant {
    ADD_OR_CHANGE => 0,
    DELETE        => 1
};

my $levelFile = "/opt/vyatta/etc/level";

# Convert level to additional groups
sub _level_groups {
    my $level = shift;
    my @groups;

    open( my $f, '<', $levelFile )
      or return;

    while (<$f>) {
        chomp;

        # Ignore blank lines and comments
        next unless $_;
        next if /^#/;

        my ( $l, $g ) = split /:/;
        if ( $l eq $level ) {
            @groups = split( /,/, $g );
            last;
        }
    }
    close $f;
    return @groups;
}

sub _authorized_keys {
    return unless eval {
        require Vyatta::Configd;
        Vyatta::Configd->import();
        1;
    };

    my $user       = shift;
    my $new_config = Vyatta::Configd::Client->new();

    # ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
    #   = getpw*
    my ( undef, undef, $uid, $gid, undef, undef, undef, $home ) =
      getpwnam($user);
    return unless $home;
    return unless -d $home;

    my $sshdir = "$home/.ssh";
    unless ( -d $sshdir ) {
        mkdir $sshdir;
        chown( $uid, $gid, $sshdir );
        chmod( 0750, $sshdir );
    }

    my $keyfile = "$sshdir/authorized_keys";
    open( my $auth, '>', $keyfile )
      or die "open $keyfile failed: $!";

    print {$auth} "# Automatically generated by Vyatta configuration\n";
    print {$auth} "# Do not edit, all changes will be lost\n";

    my $db   = $Vyatta::Configd::Client::AUTO;
    my $path = "system login user $user authentication public-keys";

    if ( $new_config->node_exists( $db, $path ) ) {
        my $subtree = decode_json $new_config->tree_get( $db, $path );

        my @pk = @{ $subtree->{"public-keys"} };
        for my $entry (@pk) {
            my $options = $entry->{"options"};
            my $type    = $entry->{"type"};
            my $key     = $entry->{"key"};
            my $name    = $entry->{"tagnode"};
            print {$auth} "$options " if $options;
            print {$auth} "$type $key $name\n";
        }
    }

    close $auth;
    chmod( 0640, $keyfile );
    chown( $uid, $gid, $keyfile );
    return;
}

sub _delete_user {
    my $user  = shift;
    my $sid   = $ENV{VYATTA_CONFIG_SID};
    my $login;
    my $result;
    my @cmd = ();
    $login = qx(ps -h -o user -p $sid 2> /dev/null) if defined $sid;

    chomp($login) if defined($login);
    # Fallback to current user (configd) only if retrieving real user fails
    $login = getlogin() unless length($login);
    if ( $user eq 'root' ) {
        warn "Disabling root account, instead of deleting\n";
        @cmd = ('usermod', '-p', '!', 'root');
        run3( \@cmd, \undef, \undef, \$result );
        if ( $result and $result ne "" ) {
            die "usermod of root failed: $result\n";
        }
    } elsif ( defined($login) && $login eq $user ) {
        warn "Attempting to delete current user: $user\n"
          . "Not removing user from system to avoid unintentional lockout.\n"
          . "Please reinstate user in config to avoid mismatch with system.\n";
    } elsif ( getpwnam($user) ) {
        if ( `who | grep "^$user"` ne '' ) {
            warn "$user is logged in, forcing logout\n";
            run3( ["pkill", "-HUP", "-u", $user], \undef, undef, undef );
        }
        run3( ["pkill", "-9", "-u", $user], \undef, undef, undef );
        my @cmd = ("pam_tally", "--user", $user, "--reset", "--quiet");
        run3( \@cmd, \undef, undef, undef );

        # check and cleanup sandbox
        my $svc = "cli-sandbox\@${user}.service";
        @cmd = ("systemctl", "-q", "is-active", ${svc});
        run3( ["systemctl", "stop", ${svc}], \undef, undef, undef )
          if ( run3( \@cmd, \undef, undef, undef ) );

        die "userdel of $user failed: $?\n"
          unless run3( ["userdel", "--remove", $user], \undef, \undef, \undef );
    }
    return;
}

sub _update_user {
    my ( $user, $tree ) = (@_);
    die "Missing input: user"   unless defined $user;
    die "Missing input: config" unless defined $tree;

    my ($pwd, $level, $fname, $home, $group);
    my $result;

    $pwd = $tree->{'authentication'}->{'encrypted-password'}
      if defined $tree->{'authentication'}->{'encrypted-password'};
    $level = $tree->{'level'}
      if defined $tree->{'level'};
    $fname = $tree->{'full-name'}
      if defined $tree->{'full-name'};
    $home = $tree->{'home-directory'}
      if defined $tree->{'home-directory'};
    $group = $tree->{'group'}
      if defined $tree->{'group'};

    unless ($pwd) {
        print "Encrypted password not specified, locking local login\n";
    }

    unless ($level) {
        warn "Level not defined for $user";
        return;
    }

    # map level to group membership
    my @groups = _level_groups($level);

    # add any additional groups from configuration
    push( @groups, @{$group} ) if defined $group;

    # Read existing settings
    my $uid = getpwnam($user);

    # not found in existing passwd, must be new
    my @cmd = ();
    unless ( defined($uid) ) {
        #  make new user using vyatta shell
        #  and make home directory (-m)
        #  and with default group of 100 (users)
        @cmd = ('useradd', '-m', '-N');
    } else {
        # update existing account
        @cmd = ('usermod', '-m');
    }

    push(@cmd, '-s', '/bin/vbash');
    if ($pwd) {
        push(@cmd, '-p', $pwd);
    } else {
        unless ( defined($uid) ) {
            # This is a useradd, the default is to lock the password.
        } else {
            # No password, lock the account
            push(@cmd, '-L');
        }
    }
    push(@cmd, '-c', $fname) if ( defined $fname );

    if ( defined $home ) {
        push(@cmd, '-d', $home);
    }
    else {
        if ( defined($uid) && $uid == 0 ) {
            push(@cmd, '-d', '/root');
        }
        else {
            push(@cmd, '-d', "/home/$user");
        }
    }
    push(@cmd, '-G', join( ',', @groups), $user);
    run3( \@cmd, \undef, \undef, \$result);
    if ( $result and $result ne "") {
        die "Attempt to change user $user failed: $result\n";
    }
    return;
}

# returns true if user is member of a vyatta* group
sub _in_vyatta_group {
    my ($name) = @_;
    my $groups = qx/groups $name/;
    return $groups =~ m/:.*vyatta/;
}

# returns list of dynamically allocated users (see Debian Policy Manual)
sub _local_users {
    my @users;

    setpwent();
    while (
        my ( $name, undef, $uid, undef, undef, undef, undef, undef, $shell ) =
        getpwent() )
    {
        next unless ( $uid >= 1000 && $uid <= 29999 );
        next unless _in_vyatta_group $name;

        push @users, $name;
    }
    endpwent();

    return @users;
}

sub update {
    return unless eval {
        require Vyatta::Configd;
        Vyatta::Configd->import();
        1;
    };

    my $config = Vyatta::Configd::Client->new();
    die "Unable to connect to the Vyatta Configuration Daemon"
      unless defined($config);

    my $ADDED   = $Vyatta::Configd::Client::ADDED;
    my $CHANGED = $Vyatta::Configd::Client::CHANGED;
    my $DELETED = $Vyatta::Configd::Client::DELETED;
    my %db      = (
        &DELETE        => $Vyatta::Configd::Client::RUNNING,
        &ADD_OR_CHANGE => $Vyatta::Configd::Client::CANDIDATE
    );
    my %users;
    foreach my $action ( keys(%db) ) {
        next unless $config->node_exists( $db{$action}, "system login user" );
        my $tree =
          decode_json $config->tree_get( $db{$action}, "system login user" );
        next unless defined $tree;
        $tree = $tree->{'user'};
        foreach my $uconfig ( @{$tree} ) {
            my $user = $uconfig->{'tagnode'};
            $users{$user} = 1;
            my $state =
              $config->node_get_status( $Vyatta::Configd::Client::AUTO,
                "system login user $user" );
            if ( $action == DELETE && $state == $DELETED ) {
                _delete_user($user);
            } elsif ( $action == ADD_OR_CHANGE
                && ( $state == $ADDED || $state == $CHANGED ) )
            {
                _update_user( $user, $uconfig );
                _authorized_keys($user);
            }
        }
    }

    # Remove any normal users that do not exist in current configuration
    # This can happen if user added but configuration not saved
    # and system is rebooted
    foreach my $user ( _local_users() ) {

        # did we see this user in configuration?
        next if defined $users{$user};

        warn "Removing $user not listed in current configuration\n";

        # Remove user account but leave home directory to be safe
        my $err = qx(userdel $user 2>&1);
        next unless $?;
        warn "Attempt to delete user $user failed\n" . $err;
    }
    return;
}

1;