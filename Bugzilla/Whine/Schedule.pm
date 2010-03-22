# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Eric Black.
# Portions created by the Initial Developer are Copyright (C) 2009 
# Eric Black. All Rights Reserved.
#
# Contributor(s): Eric Black <black.eric@gmail.com>

use strict;

package Bugzilla::Whine::Schedule;

use base qw(Bugzilla::Object);

use Bugzilla::Constants;

#############
# Constants #
#############

use constant DB_TABLE => 'whine_schedules';

use constant DB_COLUMNS => qw(
    id
    eventid
    run_day
    run_time
    run_next
    mailto
    mailto_type
);

use constant REQUIRED_CREATE_FIELDS => qw(eventid mailto mailto_type);

use constant UPDATE_COLUMNS => qw(
    eventid 
    run_day 
    run_time 
    run_next 
    mailto 
    mailto_type
);
use constant NAME_FIELD => 'id';
use constant LIST_ORDER => 'id';

####################
# Simple Accessors #
####################
sub eventid         { return $_[0]->{'eventid'};     }
sub run_day         { return $_[0]->{'run_day'};     }
sub run_time        { return $_[0]->{'run_time'};    }
sub mailto_is_group { return $_[0]->{'mailto_type'}; }

sub mailto {
    my $self = shift;

    return $self->{mailto_object} if exists $self->{mailto_object};
    my $id = $self->{'mailto'};

    if ($self->mailto_is_group) {
        $self->{mailto_object} = Bugzilla::Group->new($id);
    } else {
        $self->{mailto_object} = Bugzilla::User->new($id);
    }
    return $self->{mailto_object};
}

sub mailto_users { 
    my $self = shift;
    return $self->{mailto_users} if exists $self->{mailto_users};
    my $object = $self->mailto;

    if ($self->mailto_is_group) {
        $self->{mailto_users} = $object->members_non_inherited if $object->is_active;
    } else {
        $self->{mailto_users} = $object;
    }
    return $self->{mailto_users};
}

1;

__END__

=head1 NAME

Bugzilla::Whine::Schedule - A schedule object used by L<Bugzilla::Whine>.

=head1 SYNOPSIS

 use Bugzilla::Whine::Schedule;

 my $schedule = new Bugzilla::Whine::Schedule($schedule_id);

 my $event_id    = $schedule->eventid;
 my $run_day     = $schedule->run_day;
 my $run_time    = $schedule->run_time;
 my $is_group    = $schedule->mailto_is_group;
 my $object      = $schedule->mailto;
 my $array_ref   = $schedule->mailto_users;

=head1 DESCRIPTION

This module exists to represent a L<Bugzilla::Whine> event schedule.

This is an implementation of L<Bugzilla::Object>, and so has all the
same methods available as L<Bugzilla::Object>, in addition to what is
documented below.

=head1 METHODS

=head2 Constructors

=over

=item C<new>

Does not accept a bare C<name> argument. Instead, accepts only an id.

See also: L<Bugzilla::Object/new>.

=back


=head2 Accessors

These return data about the object, without modifying the object.

=over

=item C<event_id>

The L<Bugzilla::Whine> event object id for this object.

=item C<run_day>

The day or day pattern that a L<Bugzilla::Whine> event is scheduled to run.

=item C<run_time>

The time or time pattern that a L<Bugzilla::Whine> event is scheduled to run.

=item C<mailto_is_group>

Returns a numeric 1 (C<group>) or 0 (C<user>) to represent whether
L</mailto> is a group or user.

=item C<mailto>

This is either a L<Bugzilla::User> or L<Bugzilla::Group> object to represent 
the user or group this scheduled event is set to be mailed to. 

=item C<mailto_users>

Returns an array reference of L<Bugzilla::User>s. This is derived from the
L<Bugzilla::Group> stored in L</mailto> if L</mailto_is_group> is true and
the group is still active, otherwise it will contain a single array element
for the L<Bugzilla::User> in L</mailto>.

=back
