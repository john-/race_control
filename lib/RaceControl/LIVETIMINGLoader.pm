package LIVETIMINGLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";
use RaceControl::Utils;

use HTML::Clean;
#use HTML::TableExtract;
use Data::Dumper;
use POE::Component::Logger;

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    my $fields_as_string = $self->{config}{session}{series}{$self->{series}}{fields};
    if ($fields_as_string eq '') { # default if field list not conf for series
        $fields_as_string = $self->{config}{session}{defaultfields};
    }
    @{$self->{fields}} = split / /, $fields_as_string;
    
    return $self;
}


my %flag_map = (
    G  => 'Green',
    Y  => 'Yellow',
    R  => 'Red',
    C  => 'Checkered',
    U  => 'Unflagged',
    );

use constant EVENT => 0;
use constant FLAG =>  5;
use constant CONTROLMSG => 16;

my @cleanups = (
    [ driver     => qr{\(M\)}             ], # sometimes there is a "(M)"
    [ driver     => qr{\(R\)}             ], # Don't care if they are a rookie
    [ best_speed => qr{\+}                ], # sometimes there is a "+"
    [ position   => qr{\+}                ],
    [ status     => qr{\A\z},       'Run' ], # not all series track status
    [ status     => qr{Active}i,    'Run' ],
    [ status     => qr{In Pit}i,    'Pit' ],
    [ status     => qr{Pace_Laps}i, 'Pace'],
    );

sub get_state {
    my ($self, $contents) = @_;

    $contents =~ s/\r//g;
    
    my %session;

    foreach (split /\n/, $contents) {

 	if (/^ *\d+\+*\|/) {
	    #print "position info: $_\n";
	    
	    # break up the input and put into hash

	    my @values = split(/\|/);
	    foreach (@values) { s/^\ *//; }; # remove leading spaces from field
	    #my @values = map { s/^\ *//; } split(/\|/);
	    #foreach (@values) { print "val: $_ "; }
	    #print "\n";

	    my %stats;
	    @stats{@{$self->{fields}}} = @values;


            # do some clean up / normalization

	    foreach my $cleanup (@cleanups) {
		    my ($key, $match, $replace) = @$cleanup;

		    $stats{$key} =~ s/$match/$replace/g;
		    #Logger->log("in $key replacing $match with $replace");
		}

	    # convert time from MM:SS to seconds
	    $stats{last_lap} = RaceControl::Utils::time_to_dec($stats{last_lap});
	    $stats{best_lap} = RaceControl::Utils::time_to_dec($stats{best_lap});

	    $stats{id} = $stats{car};

	    #Logger->log(Dumper(%stats));

	    push @{$session{positions}}, \%stats;

	} elsif (/^</) {
            #print "header (LIVETIMING): $_\n";
	    my @values = split(/\|/);

            my $flag_code = $values[FLAG];
            $session{flag} = exists $flag_map{$flag_code} ? $flag_map{$flag_code} : '';  # I stopped defaulting to Blank.  Trying a blank ('') instead.  Maybe not needed after I implemented the 200 return code hack in this file

	    my $msg = $values[CONTROLMSG];
            $msg =~ s/^>//;
	    $msg =~ s/^.* : //;
	    # If flag is in control_message,  ignore it.
	    $session{control_message} = $msg unless $msg =~ /^\S+ flag/i;
	    $session{event} = $values[EVENT];
	    $session{event} =~ s/\<\!(.*)/$1/;

	    #print Dumper(%session);
	    
        } else {
	    #print "garbage: $_\n";
        }
    }

    # hack to see if we got a valid response (200 code) but not valid
    # data.  Seems like livetiming.net sometimes returns html instead
    # of .PKT info
    if ($session{event} eq '</html>') {
	%session = ();
	Logger->log('Got back bogus data from web site.  Clearing session response');
    } else {
        Logger->log((join '| ',
                    map "$_: |$session{$_}", 
                             qw/series event flag time control_message/).'|');
    }

    return %session;
}
