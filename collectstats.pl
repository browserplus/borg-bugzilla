#!/usr/bin/perl -w
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
# The Initial Developer of the Original Code is Netscape Communications
# Corporation. Portions created by Netscape are
# Copyright (C) 1998 Netscape Communications Corporation. All
# Rights Reserved.
#
# Contributor(s): Terry Weissman <terry@mozilla.org>,
#                 Harrison Page <harrison@netscape.com>
#                 Gervase Markham <gerv@gerv.net>
#                 Richard Walters <rwalters@qualcomm.com>
#                 Jean-Sebastien Guay <jean_seb@hybride.com>
#                 Frédéric Buclin <LpSolit@gmail.com>

# Run me out of cron at midnight to collect Bugzilla statistics.
#
# To run new charts for a specific date, pass it in on the command line in
# ISO (2004-08-14) format.

use strict;
use lib qw(. lib);

use List::Util qw(first);
use Cwd;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Util;
use Bugzilla::Search;
use Bugzilla::User;
use Bugzilla::Product;
use Bugzilla::Field;

# Turn off output buffering (probably needed when displaying output feedback
# in the regenerate mode).
$| = 1;

# Tidy up after graphing module
my $cwd = Cwd::getcwd();
if (chdir("graphs")) {
    unlink <./*.gif>;
    unlink <./*.png>;
    # chdir("..") doesn't work if graphs is a symlink, see bug 429378
    chdir($cwd);
}

my $dbh = Bugzilla->switch_to_shadow_db();


# To recreate the daily statistics,  run "collectstats.pl --regenerate" .
my $regenerate = 0;
if ($#ARGV >= 0 && $ARGV[0] eq "--regenerate") {
    shift(@ARGV);
    $regenerate = 1;
}

my $datadir = bz_locations()->{'datadir'};

my @myproducts = map {$_->name} Bugzilla::Product->get_all;
unshift(@myproducts, "-All-");

# As we can now customize statuses and resolutions, looking at the current list
# of legal values only is not enough as some now removed statuses and resolutions
# may have existed in the past, or have been renamed. We want them all.
my $fields = {};
foreach my $field ('bug_status', 'resolution') {
    my $values = get_legal_field_values($field);
    my $old_values = $dbh->selectcol_arrayref(
                             "SELECT bugs_activity.added
                                FROM bugs_activity
                          INNER JOIN fielddefs
                                  ON fielddefs.id = bugs_activity.fieldid
                           LEFT JOIN $field
                                  ON $field.value = bugs_activity.added
                               WHERE fielddefs.name = ?
                                 AND $field.id IS NULL

                               UNION

                              SELECT bugs_activity.removed
                                FROM bugs_activity
                          INNER JOIN fielddefs
                                  ON fielddefs.id = bugs_activity.fieldid
                           LEFT JOIN $field
                                  ON $field.value = bugs_activity.removed
                               WHERE fielddefs.name = ?
                                 AND $field.id IS NULL",
                               undef, ($field, $field));

    push(@$values, @$old_values);
    $fields->{$field} = $values;
}

my @statuses = @{$fields->{'bug_status'}};
my @resolutions = @{$fields->{'resolution'}};
# Exclude "" from the resolution list.
@resolutions = grep {$_} @resolutions;

# --regenerate was taking an enormous amount of time to query everything
# per bug, per day. Instead, we now just get all the data out of the DB
# at once and stuff it into some data structures.
my (%bug_status, %bug_resolution, %removed);
if ($regenerate) {
    %bug_resolution = @{ $dbh->selectcol_arrayref(
        'SELECT bug_id, resolution FROM bugs', {Columns=>[1,2]}) };
    %bug_status = @{ $dbh->selectcol_arrayref(
        'SELECT bug_id, bug_status FROM bugs', {Columns=>[1,2]}) };

    my $removed_sth = $dbh->prepare(
        q{SELECT bugs_activity.bug_id, bugs_activity.removed,}
        . $dbh->sql_to_days('bugs_activity.bug_when')
        . q{FROM bugs_activity
           WHERE bugs_activity.fieldid = ?
        ORDER BY bugs_activity.bug_when});

    %removed = (bug_status => {}, resolution => {});
    foreach my $field (qw(bug_status resolution)) {
        my $field_id = Bugzilla::Field->check($field)->id;
        my $rows = $dbh->selectall_arrayref($removed_sth, undef, $field_id);
        my $hash = $removed{$field};
        foreach my $row (@$rows) {
            my ($bug_id, $removed, $when) = @$row;
            $hash->{$bug_id} ||= [];
            push(@{ $hash->{$bug_id} }, { when    => int($when),
                                          removed => $removed });
        }
    }
}

my $tstart = time;
foreach (@myproducts) {
    my $dir = "$datadir/mining";

    &check_data_dir ($dir);

    if ($regenerate) {
        regenerate_stats($dir, $_, \%bug_resolution, \%bug_status, \%removed);
    } else {
        &collect_stats($dir, $_);
    }
}
my $tend = time;
# Uncomment the following line for performance testing.
#print "Total time taken " . delta_time($tstart, $tend) . "\n";

CollectSeriesData();

sub check_data_dir {
    my $dir = shift;

    if (! -d $dir) {
        mkdir $dir, 0755;
        chmod 0755, $dir;
    }
}

sub collect_stats {
    my $dir = shift;
    my $product = shift;
    my $when = localtime (time);
    my $dbh = Bugzilla->dbh;

    my $product_id;
    if ($product ne '-All-') {
        my $prod = Bugzilla::Product::check_product($product);
        $product_id = $prod->id;
    }

    # NB: Need to mangle the product for the filename, but use the real
    # product name in the query
    my $file_product = $product;
    $file_product =~ s/\//-/gs;
    my $file = join '/', $dir, $file_product;
    my $exists = -f $file;

    # if the file exists, get the old status and resolution list for that product.
    my @data;
    @data = get_old_data($file) if $exists;

    # If @data is not empty, then we have to recreate the data file.
    if (scalar(@data)) {
        open(DATA, '>', $file)
          || ThrowCodeError('chart_file_open_fail', {'filename' => $file});
    }
    else {
        open(DATA, '>>', $file)
          || ThrowCodeError('chart_file_open_fail', {'filename' => $file});
    }

    # Now collect current data.
    my @row = (today());
    my $status_sql = q{SELECT COUNT(*) FROM bugs WHERE bug_status = ?};
    my $reso_sql   = q{SELECT COUNT(*) FROM bugs WHERE resolution = ?};

    if ($product ne '-All-') {
        $status_sql .= q{ AND product_id = ?};
        $reso_sql   .= q{ AND product_id = ?};
    }

    my $sth_status = $dbh->prepare($status_sql);
    my $sth_reso   = $dbh->prepare($reso_sql);

    my @values ;
    foreach my $status (@statuses) {
        @values = ($status);
        push (@values, $product_id) if ($product ne '-All-');
        my $count = $dbh->selectrow_array($sth_status, undef, @values);
        push(@row, $count);
    }
    foreach my $resolution (@resolutions) {
        @values = ($resolution);
        push (@values, $product_id) if ($product ne '-All-');
        my $count = $dbh->selectrow_array($sth_reso, undef, @values);
        push(@row, $count);
    }

    if (!$exists || scalar(@data)) {
        my $fields = join('|', ('DATE', @statuses, @resolutions));
        print DATA <<FIN;
# Bugzilla Daily Bug Stats
#
# Do not edit me! This file is generated.
#
# fields: $fields
# Product: $product
# Created: $when
FIN
    }

    # Add existing data, if needed. Note that no count is not treated
    # the same way as a count with 0 bug.
    foreach my $data (@data) {
        print DATA join('|', map {defined $data->{$_} ? $data->{$_} : ''}
                                 ('DATE', @statuses, @resolutions)) . "\n";
    }
    print DATA (join '|', @row) . "\n";
    close DATA;
    chmod 0644, $file;
}

sub get_old_data {
    my $file = shift;

    open(DATA, '<', $file)
      || ThrowCodeError('chart_file_open_fail', {'filename' => $file});

    my @data;
    my @columns;
    my $recreate = 0;
    while (<DATA>) {
        chomp;
        next unless $_;
        if (/^# fields?:\s*(.+)\s*$/) {
            @columns = split(/\|/, $1);
            # Compare this list with @statuses and @resolutions.
            # If they are identical, then we can safely append new data
            # to the end of the file; else we have to recreate it.
            $recreate = 1;
            my @new_cols = ($columns[0], @statuses, @resolutions);
            if (scalar(@columns) == scalar(@new_cols)) {
                my $identical = 1;
                for (0 .. $#columns) {
                    $identical = 0 if ($columns[$_] ne $new_cols[$_]);
                }
                last if $identical;
            }
        }
        next unless $recreate;
        next if (/^#/); # Ignore comments.
        # If we have to recreate the file, we have to load all existing
        # data first.
        my @line = split /\|/;
        my %data;
        foreach my $column (@columns) {
            $data{$column} = shift @line;
        }
        push(@data, \%data);
    }
    close(DATA);
    return @data;
}

# This regenerates all statistics from the database.
sub regenerate_stats {
    my ($dir, $product, $bug_resolution, $bug_status, $removed) = @_;

    my $dbh = Bugzilla->dbh;
    my $when = localtime(time());
    my $tstart = time();

    # NB: Need to mangle the product for the filename, but use the real
    # product name in the query
    my $file_product = $product;
    $file_product =~ s/\//-/gs;
    my $file = join '/', $dir, $file_product;

    my $and_product = "";
    my $from_product = "";

    my @values = ();
    if ($product ne '-All-') {
        $and_product = q{ AND products.name = ?};
        $from_product = q{ INNER JOIN products 
                          ON bugs.product_id = products.id};
        push (@values, $product);
    }

    # Determine the start date from the date the first bug in the
    # database was created, and the end date from the current day.
    # If there were no bugs in the search, return early.
    my $query = q{SELECT } .
                $dbh->sql_to_days('creation_ts') . q{ AS start_day, } .
                $dbh->sql_to_days('current_date') . q{ AS end_day, } . 
                $dbh->sql_to_days("'1970-01-01'") . 
                 qq{ FROM bugs $from_product 
                   WHERE } . $dbh->sql_to_days('creation_ts') . 
                         qq{ IS NOT NULL $and_product 
                ORDER BY start_day } . $dbh->sql_limit(1);
    my ($start, $end, $base) = $dbh->selectrow_array($query, undef, @values);

    if (!defined $start) {
        return;
    }

    if (open DATA, ">$file") {
        my $fields = join('|', ('DATE', @statuses, @resolutions));
        print DATA <<FIN;
# Bugzilla Daily Bug Stats
#
# Do not edit me! This file is generated.
#
# fields: $fields
# Product: $product
# Created: $when
FIN
        # For each day, generate a line of statistics.
        my $total_days = $end - $start;
        my @bugs;
        for (my $day = $start + 1; $day <= $end; $day++) {
            # Some output feedback
            my $percent_done = ($day - $start - 1) * 100 / $total_days;
            printf "\rRegenerating $product \[\%.1f\%\%]", $percent_done;

            # Get a list of bugs that were created the previous day, and
            # add those bugs to the list of bugs for this product.
            $query = qq{SELECT bug_id 
                          FROM bugs $from_product 
                         WHERE bugs.creation_ts < } . 
                         $dbh->sql_from_days($day - 1) . 
                         q{ AND bugs.creation_ts >= } . 
                         $dbh->sql_from_days($day - 2) . 
                        $and_product . q{ ORDER BY bug_id};

            my $bug_ids = $dbh->selectcol_arrayref($query, undef, @values);
            push(@bugs, @$bug_ids);

            my %bugcount;
            foreach (@statuses) { $bugcount{$_} = 0; }
            foreach (@resolutions) { $bugcount{$_} = 0; }
            # Get information on bug states and resolutions.
            for my $bug (@bugs) {
                my $status = _get_value(
                    $removed->{'bug_status'}->{$bug},
                    $bug_status,  $day, $bug);

                if (defined $bugcount{$status}) {
                    $bugcount{$status}++;
                }

                my $resolution = _get_value(
                    $removed->{'resolution'}->{$bug},
                    $bug_resolution, $day, $bug);

                if (defined $bugcount{$resolution}) {
                    $bugcount{$resolution}++;
                }
            }

            # Generate a line of output containing the date and counts
            # of bugs in each state.
            my $date = sqlday($day, $base);
            print DATA "$date";
            foreach (@statuses) { print DATA "|$bugcount{$_}"; }
            foreach (@resolutions) { print DATA "|$bugcount{$_}"; }
            print DATA "\n";
        }
        
        # Finish up output feedback for this product.
        my $tend = time;
        print "\rRegenerating $product \[100.0\%] - " .
            delta_time($tstart, $tend) . "\n";
            
        close DATA;
        chmod 0640, $file;
    }
}

# A helper for --regenerate.
# For each bug that exists on a day, we determine its status/resolution
# at the beginning of the day.  If there were no status/resolution
# changes on or after that day, the status was the same as it
# is today (the "current" value).  Otherwise, the status was equal to the
# first "previous value" entry in the bugs_activity table for that 
# bug made on or after that day.
sub _get_value {
    my ($removed, $current, $day, $bug) = @_;

    # Get the first change that's on or after this day.
    my $item = first { $_->{when} >= $day } @{ $removed || [] };

    # If there's no change on or after this day, then we just return the
    # current value.
    return $item ? $item->{removed} : $current->{$bug};
}

sub today {
    my ($dom, $mon, $year) = (localtime(time))[3, 4, 5];
    return sprintf "%04d%02d%02d", 1900 + $year, ++$mon, $dom;
}

sub today_dash {
    my ($dom, $mon, $year) = (localtime(time))[3, 4, 5];
    return sprintf "%04d-%02d-%02d", 1900 + $year, ++$mon, $dom;
}

sub sqlday {
    my ($day, $base) = @_;
    $day = ($day - $base) * 86400;
    my ($dom, $mon, $year) = (gmtime($day))[3, 4, 5];
    return sprintf "%04d%02d%02d", 1900 + $year, ++$mon, $dom;
}

sub delta_time {
    my $tstart = shift;
    my $tend = shift;
    my $delta = $tend - $tstart;
    my $hours = int($delta/3600);
    my $minutes = int($delta/60) - ($hours * 60);
    my $seconds = $delta - ($minutes * 60) - ($hours * 3600);
    return sprintf("%02d:%02d:%02d" , $hours, $minutes, $seconds);
}

sub CollectSeriesData {
    # We need some way of randomising the distribution of series, such that
    # all of the series which are to be run every 7 days don't run on the same
    # day. This is because this might put the server under severe load if a
    # particular frequency, such as once a week, is very common. We achieve
    # this by only running queries when:
    # (days_since_epoch + series_id) % frequency = 0. So they'll run every
    # <frequency> days, but the start date depends on the series_id.
    my $days_since_epoch = int(time() / (60 * 60 * 24));
    my $today = $ARGV[0] || today_dash();

    # We save a copy of the main $dbh and then switch to the shadow and get
    # that one too. Remember, these may be the same.
    my $dbh = Bugzilla->switch_to_main_db();
    my $shadow_dbh = Bugzilla->switch_to_shadow_db();
    
    my $serieses = $dbh->selectall_hashref("SELECT series_id, query, creator " .
                      "FROM series " .
                      "WHERE frequency != 0 AND " . 
                      "MOD(($days_since_epoch + series_id), frequency) = 0",
                      "series_id");

    # We prepare the insertion into the data table, for efficiency.
    my $sth = $dbh->prepare("INSERT INTO series_data " .
                            "(series_id, series_date, series_value) " .
                            "VALUES (?, " . $dbh->quote($today) . ", ?)");

    # We delete from the table beforehand, to avoid SQL errors if people run
    # collectstats.pl twice on the same day.
    my $deletesth = $dbh->prepare("DELETE FROM series_data 
                                   WHERE series_id = ? AND series_date = " .
                                   $dbh->quote($today));
                                     
    foreach my $series_id (keys %$serieses) {
        # We set up the user for Search.pm's permission checking - each series
        # runs with the permissions of its creator.
        my $user = new Bugzilla::User($serieses->{$series_id}->{'creator'});
        my $cgi = new Bugzilla::CGI($serieses->{$series_id}->{'query'});
        my $data;

        # Do not die if Search->new() detects invalid data, such as an obsolete
        # login name or a renamed product or component, etc.
        eval {
            my $search = new Bugzilla::Search('params' => $cgi,
                                              'fields' => ["bug_id"],
                                              'user'   => $user);
            my $sql = $search->getSQL();
            $data = $shadow_dbh->selectall_arrayref($sql);
        };

        if (!$@) {
            # We need to count the returned rows. Without subselects, we can't
            # do this directly in the SQL for all queries. So we do it by hand.
            my $count = scalar(@$data) || 0;

            $deletesth->execute($series_id);
            $sth->execute($series_id, $count);
        }
    }
}

