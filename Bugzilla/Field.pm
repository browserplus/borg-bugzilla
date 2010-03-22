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
# Contributor(s): Dan Mosedale <dmose@mozilla.org>
#                 Frédéric Buclin <LpSolit@gmail.com>
#                 Myk Melez <myk@mozilla.org>
#                 Greg Hendricks <ghendricks@novell.com>

=head1 NAME

Bugzilla::Field - a particular piece of information about bugs
                  and useful routines for form field manipulation

=head1 SYNOPSIS

  use Bugzilla;
  use Data::Dumper;

  # Display information about all fields.
  print Dumper(Bugzilla->get_fields());

  # Display information about non-obsolete custom fields.
  print Dumper(Bugzilla->active_custom_fields);

  use Bugzilla::Field;

  # Display information about non-obsolete custom fields.
  # Bugzilla->get_fields() is a wrapper around Bugzilla::Field->match(),
  # so both methods take the same arguments.
  print Dumper(Bugzilla::Field->match({ obsolete => 0, custom => 1 }));

  # Create or update a custom field or field definition.
  my $field = Bugzilla::Field->create(
    {name => 'cf_silly', description => 'Silly', custom => 1});

  # Instantiate a Field object for an existing field.
  my $field = new Bugzilla::Field({name => 'qacontact_accessible'});
  if ($field->obsolete) {
      print $field->description . " is obsolete\n";
  }

  # Validation Routines
  check_field($name, $value, \@legal_values, $no_warn);
  $fieldid = get_field_id($fieldname);

=head1 DESCRIPTION

Field.pm defines field objects, which represent the particular pieces
of information that Bugzilla stores about bugs.

This package also provides functions for dealing with CGI form fields.

C<Bugzilla::Field> is an implementation of L<Bugzilla::Object>, and
so provides all of the methods available in L<Bugzilla::Object>,
in addition to what is documented here.

=cut

package Bugzilla::Field;

use strict;

use base qw(Exporter Bugzilla::Object);
@Bugzilla::Field::EXPORT = qw(check_field get_field_id get_legal_field_values);

use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Util;

use Scalar::Util qw(blessed);

###############################
####    Initialization     ####
###############################

use constant DB_TABLE   => 'fielddefs';
use constant LIST_ORDER => 'sortkey, name';

use constant DB_COLUMNS => qw(
    id
    name
    description
    type
    custom
    mailhead
    sortkey
    obsolete
    enter_bug
    buglist
    visibility_field_id
    visibility_value_id
    value_field_id
);

use constant REQUIRED_CREATE_FIELDS => qw(name description);

use constant VALIDATORS => {
    custom      => \&_check_custom,
    description => \&_check_description,
    enter_bug   => \&_check_enter_bug,
    buglist     => \&Bugzilla::Object::check_boolean,
    mailhead    => \&_check_mailhead,
    obsolete    => \&_check_obsolete,
    sortkey     => \&_check_sortkey,
    type        => \&_check_type,
    visibility_field_id => \&_check_visibility_field_id,
};

use constant UPDATE_VALIDATORS => {
    value_field_id      => \&_check_value_field_id,
    visibility_value_id => \&_check_control_value,
};

use constant UPDATE_COLUMNS => qw(
    description
    mailhead
    sortkey
    obsolete
    enter_bug
    buglist
    visibility_field_id
    visibility_value_id
    value_field_id

    type
);

# How various field types translate into SQL data definitions.
use constant SQL_DEFINITIONS => {
    # Using commas because these are constants and they shouldn't
    # be auto-quoted by the "=>" operator.
    FIELD_TYPE_FREETEXT,      { TYPE => 'varchar(255)' },
    FIELD_TYPE_SINGLE_SELECT, { TYPE => 'varchar(64)', NOTNULL => 1,
                                DEFAULT => "'---'" },
    FIELD_TYPE_TEXTAREA,      { TYPE => 'MEDIUMTEXT' },
    FIELD_TYPE_DATETIME,      { TYPE => 'DATETIME'   },
    FIELD_TYPE_BUG_ID,        { TYPE => 'INT3'       },
};

# Field definitions for the fields that ship with Bugzilla.
# These are used by populate_field_definitions to populate
# the fielddefs table.
use constant DEFAULT_FIELDS => (
    {name => 'bug_id',       desc => 'Bug #',      in_new_bugmail => 1,
     buglist => 1},
    {name => 'short_desc',   desc => 'Summary',    in_new_bugmail => 1,
     buglist => 1},
    {name => 'classification', desc => 'Classification', in_new_bugmail => 1,
     buglist => 1},
    {name => 'product',      desc => 'Product',    in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'version',      desc => 'Version',    in_new_bugmail => 1,
     buglist => 1},
    {name => 'rep_platform', desc => 'Platform',   in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'bug_file_loc', desc => 'URL',        in_new_bugmail => 1},
    {name => 'op_sys',       desc => 'OS/Version', in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'bug_status',   desc => 'Status',     in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'status_whiteboard', desc => 'Status Whiteboard',
     in_new_bugmail => 1, buglist => 1},
    {name => 'keywords',     desc => 'Keywords',   in_new_bugmail => 1,
     buglist => 1},
    {name => 'resolution',   desc => 'Resolution',
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'bug_severity', desc => 'Severity',   in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'priority',     desc => 'Priority',   in_new_bugmail => 1,
     type => FIELD_TYPE_SINGLE_SELECT, buglist => 1},
    {name => 'component',    desc => 'Component',  in_new_bugmail => 1,
     buglist => 1},
    {name => 'assigned_to',  desc => 'AssignedTo', in_new_bugmail => 1,
     buglist => 1},
    {name => 'reporter',     desc => 'ReportedBy', in_new_bugmail => 1,
     buglist => 1},
    {name => 'votes',        desc => 'Votes',      buglist => 1},
    {name => 'qa_contact',   desc => 'QAContact',  in_new_bugmail => 1,
     buglist => 1},
    {name => 'cc',           desc => 'CC',         in_new_bugmail => 1},
    {name => 'dependson',    desc => 'Depends on', in_new_bugmail => 1},
    {name => 'blocked',      desc => 'Blocks',     in_new_bugmail => 1},

    {name => 'attachments.description', desc => 'Attachment description'},
    {name => 'attachments.filename',    desc => 'Attachment filename'},
    {name => 'attachments.mimetype',    desc => 'Attachment mime type'},
    {name => 'attachments.ispatch',     desc => 'Attachment is patch'},
    {name => 'attachments.isobsolete',  desc => 'Attachment is obsolete'},
    {name => 'attachments.isprivate',   desc => 'Attachment is private'},
    {name => 'attachments.submitter',   desc => 'Attachment creator'},

    {name => 'target_milestone',      desc => 'Target Milestone',
     buglist => 1},
    {name => 'creation_ts',           desc => 'Creation date',
     in_new_bugmail => 1, buglist => 1},
    {name => 'delta_ts',              desc => 'Last changed date',
     in_new_bugmail => 1, buglist => 1},
    {name => 'longdesc',              desc => 'Comment'},
    {name => 'longdescs.isprivate',   desc => 'Comment is private'},
    {name => 'alias',                 desc => 'Alias', buglist => 1},
    {name => 'everconfirmed',         desc => 'Ever Confirmed'},
    {name => 'reporter_accessible',   desc => 'Reporter Accessible'},
    {name => 'cclist_accessible',     desc => 'CC Accessible'},
    {name => 'bug_group',             desc => 'Group', in_new_bugmail => 1},
    {name => 'estimated_time',        desc => 'Estimated Hours',
     in_new_bugmail => 1, buglist => 1},
    {name => 'remaining_time',        desc => 'Remaining Hours', buglist => 1},
    {name => 'deadline',              desc => 'Deadline',
     in_new_bugmail => 1, buglist => 1},
    {name => 'commenter',             desc => 'Commenter'},
    {name => 'flagtypes.name',        desc => 'Flags', buglist => 1},
    {name => 'requestees.login_name', desc => 'Flag Requestee'},
    {name => 'setters.login_name',    desc => 'Flag Setter'},
    {name => 'work_time',             desc => 'Hours Worked', buglist => 1},
    {name => 'percentage_complete',   desc => 'Percentage Complete',
     buglist => 1},
    {name => 'content',               desc => 'Content'},
    {name => 'attach_data.thedata',   desc => 'Attachment data'},
    {name => 'attachments.isurl',     desc => 'Attachment is a URL'},
    {name => "owner_idle_time",       desc => "Time Since Assignee Touched"},
    {name => 'see_also',              desc => "See Also",
     type => FIELD_TYPE_BUG_URLS},
);

################
# Constructors #
################

# Override match to add is_select.
sub match {
    my $self = shift;
    my ($params) = @_;
    if (delete $params->{is_select}) {
        $params->{type} = [FIELD_TYPE_SINGLE_SELECT, FIELD_TYPE_MULTI_SELECT];
    }
    return $self->SUPER::match(@_);
}

##############
# Validators #
##############

sub _check_custom { return $_[1] ? 1 : 0; }

sub _check_description {
    my ($invocant, $desc) = @_;
    $desc = clean_text($desc);
    $desc || ThrowUserError('field_missing_description');
    return $desc;
}

sub _check_enter_bug { return $_[1] ? 1 : 0; }

sub _check_mailhead { return $_[1] ? 1 : 0; }

sub _check_name {
    my ($invocant, $name, $is_custom) = @_;
    $name = lc(clean_text($name));
    $name || ThrowUserError('field_missing_name');

    # Don't want to allow a name that might mess up SQL.
    my $name_regex = qr/^[\w\.]+$/;
    # Custom fields have more restrictive name requirements than
    # standard fields.
    $name_regex = qr/^[a-zA-Z0-9_]+$/ if $is_custom;
    # Custom fields can't be named just "cf_", and there is no normal
    # field named just "cf_".
    ($name =~ $name_regex && $name ne "cf_")
         || ThrowUserError('field_invalid_name', { name => $name });

    # If it's custom, prepend cf_ to the custom field name to distinguish 
    # it from standard fields.
    if ($name !~ /^cf_/ && $is_custom) {
        $name = 'cf_' . $name;
    }

    # Assure the name is unique. Names can't be changed, so we don't have
    # to worry about what to do on updates.
    my $field = new Bugzilla::Field({ name => $name });
    ThrowUserError('field_already_exists', {'field' => $field }) if $field;

    return $name;
}

sub _check_obsolete { return $_[1] ? 1 : 0; }

sub _check_sortkey {
    my ($invocant, $sortkey) = @_;
    my $skey = $sortkey;
    if (!defined $skey || $skey eq '') {
        ($sortkey) = Bugzilla->dbh->selectrow_array(
            'SELECT MAX(sortkey) + 100 FROM fielddefs') || 100;
    }
    detaint_natural($sortkey)
        || ThrowUserError('field_invalid_sortkey', { sortkey => $skey });
    return $sortkey;
}

sub _check_type {
    my ($invocant, $type) = @_;
    my $saved_type = $type;
    # The constant here should be updated every time a new,
    # higher field type is added.
    (detaint_natural($type) && $type <= FIELD_TYPE_BUG_URLS)
      || ThrowCodeError('invalid_customfield_type', { type => $saved_type });
    return $type;
}

sub _check_value_field_id {
    my ($invocant, $field_id, $is_select) = @_;
    $is_select = $invocant->is_select if !defined $is_select;
    if ($field_id && !$is_select) {
        ThrowUserError('field_value_control_select_only');
    }
    return $invocant->_check_visibility_field_id($field_id);
}

sub _check_visibility_field_id {
    my ($invocant, $field_id) = @_;
    $field_id = trim($field_id);
    return undef if !$field_id;
    my $field = Bugzilla::Field->check({ id => $field_id });
    if (blessed($invocant) && $field->id == $invocant->id) {
        ThrowUserError('field_cant_control_self', { field => $field });
    }
    if (!$field->is_select) {
        ThrowUserError('field_control_must_be_select',
                       { field => $field });
    }
    return $field->id;
}

sub _check_control_value {
    my ($invocant, $value_id, $field_id) = @_;
    my $field;
    if (blessed $invocant) {
        $field = $invocant->visibility_field;
    }
    elsif ($field_id) {
        $field = $invocant->new($field_id);
    }
    # When no field is set, no value is set.
    return undef if !$field;
    my $value_obj = Bugzilla::Field::Choice->type($field)
                    ->check({ id => $value_id });
    return $value_obj->id;
}

=pod

=head2 Instance Properties

=over

=item C<name>

the name of the field in the database; begins with "cf_" if field
is a custom field, but test the value of the boolean "custom" property
to determine if a given field is a custom field;

=item C<description>

a short string describing the field; displayed to Bugzilla users
in several places within Bugzilla's UI, f.e. as the form field label
on the "show bug" page;

=back

=cut

sub description { return $_[0]->{description} }

=over

=item C<type>

an integer specifying the kind of field this is; values correspond to
the FIELD_TYPE_* constants in Constants.pm

=back

=cut

sub type { return $_[0]->{type} }

=over

=item C<custom>

a boolean specifying whether or not the field is a custom field;
if true, field name should start "cf_", but use this property to determine
which fields are custom fields;

=back

=cut

sub custom { return $_[0]->{custom} }

=over

=item C<in_new_bugmail>

a boolean specifying whether or not the field is displayed in bugmail
for newly-created bugs;

=back

=cut

sub in_new_bugmail { return $_[0]->{mailhead} }

=over

=item C<sortkey>

an integer specifying the sortkey of the field.

=back

=cut

sub sortkey { return $_[0]->{sortkey} }

=over

=item C<obsolete>

a boolean specifying whether or not the field is obsolete;

=back

=cut

sub obsolete { return $_[0]->{obsolete} }

=over

=item C<enter_bug>

A boolean specifying whether or not this field should appear on 
enter_bug.cgi

=back

=cut

sub enter_bug { return $_[0]->{enter_bug} }

=over

=item C<buglist>

A boolean specifying whether or not this field is selectable
as a display or order column in buglist.cgi

=back

=cut

sub buglist { return $_[0]->{buglist} }

=over

=item C<is_select>

True if this is a C<FIELD_TYPE_SINGLE_SELECT> or C<FIELD_TYPE_MULTI_SELECT>
field. It is only safe to call L</legal_values> if this is true.

=item C<legal_values>

Valid values for this field, as an array of L<Bugzilla::Field::Choice>
objects.

=back

=cut

sub is_select { 
    return ($_[0]->type == FIELD_TYPE_SINGLE_SELECT 
            || $_[0]->type == FIELD_TYPE_MULTI_SELECT) ? 1 : 0 
}

sub legal_values {
    my $self = shift;

    if (!defined $self->{'legal_values'}) {
        require Bugzilla::Field::Choice;
        my @values = Bugzilla::Field::Choice->type($self)->get_all();
        $self->{'legal_values'} = \@values;
    }
    return $self->{'legal_values'};
}

=pod

=over

=item C<visibility_field>

What field controls this field's visibility? Returns a C<Bugzilla::Field>
object representing the field that controls this field's visibility.

Returns undef if there is no field that controls this field's visibility.

=back

=cut

sub visibility_field {
    my $self = shift;
    if ($self->{visibility_field_id}) {
        $self->{visibility_field} ||= 
            $self->new($self->{visibility_field_id});
    }
    return $self->{visibility_field};
}

=pod

=over

=item C<visibility_value>

If we have a L</visibility_field>, then what value does that field have to
be set to in order to show this field? Returns a L<Bugzilla::Field::Choice>
or undef if there is no C<visibility_field> set.

=back

=cut


sub visibility_value {
    my $self = shift;
    if ($self->{visibility_field_id}) {
        require Bugzilla::Field::Choice;
        $self->{visibility_value} ||=
            Bugzilla::Field::Choice->type($self->visibility_field)->new(
                $self->{visibility_value_id});
    }
    return $self->{visibility_value};
}

=pod

=over

=item C<controls_visibility_of>

An arrayref of C<Bugzilla::Field> objects, representing fields that this
field controls the visibility of.

=back

=cut

sub controls_visibility_of {
    my $self = shift;
    $self->{controls_visibility_of} ||= 
        Bugzilla::Field->match({ visibility_field_id => $self->id });
    return $self->{controls_visibility_of};
}

=pod

=over

=item C<value_field>

The Bugzilla::Field that controls the list of values for this field.

Returns undef if there is no field that controls this field's visibility.

=back

=cut

sub value_field {
    my $self = shift;
    if ($self->{value_field_id}) {
        $self->{value_field} ||= $self->new($self->{value_field_id});
    }
    return $self->{value_field};
}

=pod

=over

=item C<controls_values_of>

An arrayref of C<Bugzilla::Field> objects, representing fields that this
field controls the values of.

=back

=cut

sub controls_values_of {
    my $self = shift;
    $self->{controls_values_of} ||=
        Bugzilla::Field->match({ value_field_id => $self->id });
    return $self->{controls_values_of};
}

=pod

=head2 Instance Mutators

These set the particular field that they are named after.

They take a single value--the new value for that field.

They will throw an error if you try to set the values to something invalid.

=over

=item C<set_description>

=item C<set_enter_bug>

=item C<set_obsolete>

=item C<set_sortkey>

=item C<set_in_new_bugmail>

=item C<set_buglist>

=item C<set_visibility_field>

=item C<set_visibility_value>

=item C<set_value_field>

=back

=cut

sub set_description    { $_[0]->set('description', $_[1]); }
sub set_enter_bug      { $_[0]->set('enter_bug',   $_[1]); }
sub set_obsolete       { $_[0]->set('obsolete',    $_[1]); }
sub set_sortkey        { $_[0]->set('sortkey',     $_[1]); }
sub set_in_new_bugmail { $_[0]->set('mailhead',    $_[1]); }
sub set_buglist        { $_[0]->set('buglist',     $_[1]); }
sub set_visibility_field {
    my ($self, $value) = @_;
    $self->set('visibility_field_id', $value);
    delete $self->{visibility_field};
    delete $self->{visibility_value};
}
sub set_visibility_value {
    my ($self, $value) = @_;
    $self->set('visibility_value_id', $value);
    delete $self->{visibility_value};
}
sub set_value_field {
    my ($self, $value) = @_;
    $self->set('value_field_id', $value);
    delete $self->{value_field};
}

# This is only used internally by upgrade code in Bugzilla::Field.
sub _set_type { $_[0]->set('type', $_[1]); }

=pod

=head2 Instance Method

=over

=item C<remove_from_db>

Attempts to remove the passed in field from the database.
Deleting a field is only successful if the field is obsolete and
there are no values specified (or EVER specified) for the field.

=back

=cut

sub remove_from_db {
    my $self = shift;
    my $dbh = Bugzilla->dbh;

    my $name = $self->name;

    if (!$self->custom) {
        ThrowCodeError('field_not_custom', {'name' => $name });
    }

    if (!$self->obsolete) {
        ThrowUserError('customfield_not_obsolete', {'name' => $self->name });
    }

    $dbh->bz_start_transaction();

    # Check to see if bug activity table has records (should be fast with index)
    my $has_activity = $dbh->selectrow_array("SELECT COUNT(*) FROM bugs_activity
                                      WHERE fieldid = ?", undef, $self->id);
    if ($has_activity) {
        ThrowUserError('customfield_has_activity', {'name' => $name });
    }

    # Check to see if bugs table has records (slow)
    my $bugs_query = "";

    if ($self->type == FIELD_TYPE_MULTI_SELECT) {
        $bugs_query = "SELECT COUNT(*) FROM bug_$name";
    }
    else {
        $bugs_query = "SELECT COUNT(*) FROM bugs WHERE $name IS NOT NULL
                                AND $name != ''";
        # Ignore the default single select value
        if ($self->type == FIELD_TYPE_SINGLE_SELECT) {
            $bugs_query .= " AND $name != '---'";
        }
        # Ignore blank dates.
        if ($self->type == FIELD_TYPE_DATETIME) {
            $bugs_query .= " AND $name != '00-00-00 00:00:00'";
        }
    }

    my $has_bugs = $dbh->selectrow_array($bugs_query);
    if ($has_bugs) {
        ThrowUserError('customfield_has_contents', {'name' => $name });
    }

    # Once we reach here, we should be OK to delete.
    $dbh->do('DELETE FROM fielddefs WHERE id = ?', undef, $self->id);

    my $type = $self->type;

    # the values for multi-select are stored in a seperate table
    if ($type != FIELD_TYPE_MULTI_SELECT) {
        $dbh->bz_drop_column('bugs', $name);
    }

    if ($self->is_select) {
        # Delete the table that holds the legal values for this field.
        $dbh->bz_drop_field_tables($self);
    }

    $dbh->bz_commit_transaction()
}

=pod

=head2 Class Methods

=over

=item C<create>

Just like L<Bugzilla::Object/create>. Takes the following parameters:

=over

=item C<name> B<Required> - The name of the field.

=item C<description> B<Required> - The field label to display in the UI.

=item C<mailhead> - boolean - Whether this field appears at the
top of the bugmail for a newly-filed bug. Defaults to 0.

=item C<custom> - boolean - True if this is a Custom Field. The field
will be added to the C<bugs> table if it does not exist. Defaults to 0.

=item C<sortkey> - integer - The sortkey of the field. Defaults to 0.

=item C<enter_bug> - boolean - Whether this field is
editable on the bug creation form. Defaults to 0.

=item C<buglist> - boolean - Whether this field is
selectable as a display or order column in bug lists. Defaults to 0.

C<obsolete> - boolean - Whether this field is obsolete. Defaults to 0.

=back

=back

=cut

sub create {
    my $class = shift;
    my $field = $class->SUPER::create(@_);

    my $dbh = Bugzilla->dbh;
    if ($field->custom) {
        my $name = $field->name;
        my $type = $field->type;
        if (SQL_DEFINITIONS->{$type}) {
            # Create the database column that stores the data for this field.
            $dbh->bz_add_column('bugs', $name, SQL_DEFINITIONS->{$type});
        }

        if ($field->is_select) {
            # Create the table that holds the legal values for this field.
            $dbh->bz_add_field_tables($field);
        }

        if ($type == FIELD_TYPE_SINGLE_SELECT) {
            # Insert a default value of "---" into the legal values table.
            $dbh->do("INSERT INTO $name (value) VALUES ('---')");
        }
    }

    return $field;
}

sub run_create_validators {
    my $class = shift;
    my $dbh = Bugzilla->dbh;
    my $params = $class->SUPER::run_create_validators(@_);

    $params->{name} = $class->_check_name($params->{name}, $params->{custom});
    if (!exists $params->{sortkey}) {
        $params->{sortkey} = $dbh->selectrow_array(
            "SELECT MAX(sortkey) + 100 FROM fielddefs") || 100;
    }

    $params->{visibility_value_id} = 
        $class->_check_control_value($params->{visibility_value_id},
                                     $params->{visibility_field_id});

    my $type = $params->{type} || 0;
    
    if ($params->{custom} && !$type) {
        ThrowCodeError('field_type_not_specified');
    }
    
    $params->{value_field_id} = 
        $class->_check_value_field_id($params->{value_field_id},
            ($type == FIELD_TYPE_SINGLE_SELECT 
             || $type == FIELD_TYPE_MULTI_SELECT) ? 1 : 0);
    return $params;
}

sub update {
    my $self = shift;
    my $changes = $self->SUPER::update(@_);
    my $dbh = Bugzilla->dbh;
    if ($changes->{value_field_id} && $self->is_select) {
        $dbh->do("UPDATE " . $self->name . " SET visibility_value_id = NULL");
    }
    return $changes;
}


=pod

=over

=item C<get_legal_field_values($field)>

Description: returns all the legal values for a field that has a
             list of legal values, like rep_platform or resolution.
             The table where these values are stored must at least have
             the following columns: value, isactive, sortkey.

Params:    C<$field> - Name of the table where valid values are.

Returns:   a reference to a list of valid values.

=back

=cut

sub get_legal_field_values {
    my ($field) = @_;
    my $dbh = Bugzilla->dbh;
    my $result_ref = $dbh->selectcol_arrayref(
         "SELECT value FROM $field
           WHERE isactive = ?
        ORDER BY sortkey, value", undef, (1));
    return $result_ref;
}

=over

=item C<populate_field_definitions()>

Description: Populates the fielddefs table during an installation
             or upgrade.

Params:      none

Returns:     nothing

=back

=cut

sub populate_field_definitions {
    my $dbh = Bugzilla->dbh;

    # ADD and UPDATE field definitions
    foreach my $def (DEFAULT_FIELDS) {
        my $field = new Bugzilla::Field({ name => $def->{name} });
        if ($field) {
            $field->set_description($def->{desc});
            $field->set_in_new_bugmail($def->{in_new_bugmail});
            $field->set_buglist($def->{buglist});
            $field->_set_type($def->{type}) if $def->{type};
            $field->update();
        }
        else {
            if (exists $def->{in_new_bugmail}) {
                $def->{mailhead} = $def->{in_new_bugmail};
                delete $def->{in_new_bugmail};
            }
            $def->{description} = delete $def->{desc};
            Bugzilla::Field->create($def);
        }
    }

    # DELETE fields which were added only accidentally, or which
    # were never tracked in bugs_activity. Note that you can never
    # delete fields which are used by bugs_activity.

    # Oops. Bug 163299
    $dbh->do("DELETE FROM fielddefs WHERE name='cc_accessible'");
    # Oops. Bug 215319
    $dbh->do("DELETE FROM fielddefs WHERE name='requesters.login_name'");
    # This field was never tracked in bugs_activity, so it's safe to delete.
    $dbh->do("DELETE FROM fielddefs WHERE name='attachments.thedata'");

    # MODIFY old field definitions

    # 2005-11-13 LpSolit@gmail.com - Bug 302599
    # One of the field names was a fragment of SQL code, which is DB dependent.
    # We have to rename it to a real name, which is DB independent.
    my $new_field_name = 'days_elapsed';
    my $field_description = 'Days since bug changed';

    my ($old_field_id, $old_field_name) =
        $dbh->selectrow_array('SELECT id, name FROM fielddefs
                                WHERE description = ?',
                              undef, $field_description);

    if ($old_field_id && ($old_field_name ne $new_field_name)) {
        print "SQL fragment found in the 'fielddefs' table...\n";
        print "Old field name: " . $old_field_name . "\n";
        # We have to fix saved searches first. Queries have been escaped
        # before being saved. We have to do the same here to find them.
        $old_field_name = url_quote($old_field_name);
        my $broken_named_queries =
            $dbh->selectall_arrayref('SELECT userid, name, query
                                        FROM namedqueries WHERE ' .
                                      $dbh->sql_istrcmp('query', '?', 'LIKE'),
                                      undef, "%=$old_field_name%");

        my $sth_UpdateQueries = $dbh->prepare('UPDATE namedqueries SET query = ?
                                                WHERE userid = ? AND name = ?');

        print "Fixing saved searches...\n" if scalar(@$broken_named_queries);
        foreach my $named_query (@$broken_named_queries) {
            my ($userid, $name, $query) = @$named_query;
            $query =~ s/=\Q$old_field_name\E(&|$)/=$new_field_name$1/gi;
            $sth_UpdateQueries->execute($query, $userid, $name);
        }

        # We now do the same with saved chart series.
        my $broken_series =
            $dbh->selectall_arrayref('SELECT series_id, query
                                        FROM series WHERE ' .
                                      $dbh->sql_istrcmp('query', '?', 'LIKE'),
                                      undef, "%=$old_field_name%");

        my $sth_UpdateSeries = $dbh->prepare('UPDATE series SET query = ?
                                               WHERE series_id = ?');

        print "Fixing saved chart series...\n" if scalar(@$broken_series);
        foreach my $series (@$broken_series) {
            my ($series_id, $query) = @$series;
            $query =~ s/=\Q$old_field_name\E(&|$)/=$new_field_name$1/gi;
            $sth_UpdateSeries->execute($query, $series_id);
        }
        # Now that saved searches have been fixed, we can fix the field name.
        print "Fixing the 'fielddefs' table...\n";
        print "New field name: " . $new_field_name . "\n";
        $dbh->do('UPDATE fielddefs SET name = ? WHERE id = ?',
                  undef, ($new_field_name, $old_field_id));
    }

    # This field has to be created separately, or the above upgrade code
    # might not run properly.
    Bugzilla::Field->create({ name => $new_field_name, 
                              description => $field_description })
        unless new Bugzilla::Field({ name => $new_field_name });

}



=head2 Data Validation

=over

=item C<check_field($name, $value, \@legal_values, $no_warn)>

Description: Makes sure the field $name is defined and its $value
             is non empty. If @legal_values is defined, this routine
             checks whether its value is one of the legal values
             associated with this field, else it checks against
             the default valid values for this field obtained by
             C<get_legal_field_values($name)>. If the test is successful,
             the function returns 1. If the test fails, an error
             is thrown (by default), unless $no_warn is true, in which
             case the function returns 0.

Params:      $name         - the field name
             $value        - the field value
             @legal_values - (optional) list of legal values
             $no_warn      - (optional) do not throw an error if true

Returns:     1 on success; 0 on failure if $no_warn is true (else an
             error is thrown).

=back

=cut

sub check_field {
    my ($name, $value, $legalsRef, $no_warn) = @_;
    my $dbh = Bugzilla->dbh;

    # If $legalsRef is undefined, we use the default valid values.
    # Valid values for this check are all possible values. 
    # Using get_legal_values would only return active values, but since
    # some bugs may have inactive values set, we want to check them too. 
    unless (defined $legalsRef) {
        $legalsRef = Bugzilla::Field->new({name => $name})->legal_values;
        my @values = map($_->name, @$legalsRef);
        $legalsRef = \@values;

    }

    if (!defined($value)
        || trim($value) eq ""
        || lsearch($legalsRef, $value) < 0)
    {
        return 0 if $no_warn; # We don't want an error to be thrown; return.
        trick_taint($name);

        my $field = new Bugzilla::Field({ name => $name });
        my $field_desc = $field ? $field->description : $name;
        ThrowCodeError('illegal_field', { field => $field_desc });
    }
    return 1;
}

=pod

=over

=item C<get_field_id($fieldname)>

Description: Returns the ID of the specified field name and throws
             an error if this field does not exist.

Params:      $name - a field name

Returns:     the corresponding field ID or an error if the field name
             does not exist.

=back

=cut

sub get_field_id {
    my ($name) = @_;
    my $dbh = Bugzilla->dbh;

    trick_taint($name);
    my $id = $dbh->selectrow_array('SELECT id FROM fielddefs
                                    WHERE name = ?', undef, $name);

    ThrowCodeError('invalid_field_name', {field => $name}) unless $id;
    return $id
}

1;

__END__
