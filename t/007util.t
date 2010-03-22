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
# The Original Code are the Bugzilla Tests.
# 
# The Initial Developer of the Original Code is Zach Lipton
# Portions created by Zach Lipton are Copyright (C) 2002 Zach Lipton.
# All Rights Reserved.
# 
# Contributor(s): Zach Lipton <zach@zachlipton.com>
#                 Max Kanat-Alexander <mkanat@bugzilla.org>


#################
#Bugzilla Test 7#
#####Util.pm#####

use lib 't';
use Support::Files;
use Test::More tests => 16;

BEGIN { 
    use_ok(Bugzilla);
    use_ok(Bugzilla::Util);
}

# We need to override user preferences so we can get an expected value when
# Bugzilla::Util::format_time() calls ask for the 'timezone' user preference.
Bugzilla->user->{'settings'}->{'timezone'}->{'value'} = "local";

# We need to know the local timezone for the date chosen in our tests.
# Below, tests are run against Nov. 24, 2002.
my $tz = Bugzilla->local_timezone->short_name_for_datetime(DateTime->new(year => 2002, month => 11, day => 24));

# we don't test the taint functions since that's going to take some more work.
# XXX: test taint functions

#html_quote():
is(html_quote("<lala&@>"),"&lt;lala&amp;&#64;&gt;",'html_quote');

#url_quote():
is(url_quote("<lala&>gaa\"'[]{\\"),"%3Clala%26%3Egaa%22%27%5B%5D%7B%5C",'url_quote');

#lsearch():
my @list = ('apple','pear','plum','<"\\%');
is(lsearch(\@list,'pear'),1,'lsearch 1');
is(lsearch(\@list,'<"\\%'),3,'lsearch 2');
is(lsearch(\@list,'kiwi'),-1,'lsearch 3 (missing item)');

#trim():
is(trim(" fg<*\$%>+=~~ "),'fg<*$%>+=~~','trim()');

#format_time();
is(format_time("2002.11.24 00:05"), "2002-11-24 00:05 $tz",'format_time("2002.11.24 00:05") is ' . format_time("2002.11.24 00:05"));
is(format_time("2002.11.24 00:05:56"), "2002-11-24 00:05:56 $tz",'format_time("2002.11.24 00:05:56")');
is(format_time("2002.11.24 00:05:56", "%Y-%m-%d %R"), '2002-11-24 00:05', 'format_time("2002.11.24 00:05:56", "%Y-%m-%d %R") (with no timezone)');
is(format_time("2002.11.24 00:05:56", "%Y-%m-%d %R %Z"), "2002-11-24 00:05 $tz", 'format_time("2002.11.24 00:05:56", "%Y-%m-%d %R %Z") (with timezone)');

# email_filter
my %email_strings = (
    'somebody@somewhere.com' => 'somebody',
    'Somebody <somebody@somewhere.com>' => 'Somebody <somebody>',
    'One Person <one@person.com>, Two Person <two@person.com>' 
        => 'One Person <one>, Two Person <two>',
    'This string contains somebody@somewhere.com and also this@that.com'
        => 'This string contains somebody and also this',
);
foreach my $input (keys %email_strings) {
    is(Bugzilla::Util::email_filter($input), $email_strings{$input}, 
       "email_filter('$input')");
}
