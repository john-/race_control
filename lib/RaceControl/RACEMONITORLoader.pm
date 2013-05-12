package RACEMONITORLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";
use RaceControl::Utils;

use POE::Filter::CSV;
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

    $self->{field} = ();      # Store car/drive info
    $self->{order} = [];      # Running order
    $self->{class} = ();      # Car class information
    $self->{carryover} = '';  # from previous time called
    
    return $self;
}


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

#   this should be done at field level
#    foreach my $cleanup (@cleanups) {
#        my ($key, $match, $replace) = @$cleanup;

#       $contents =~ s/$match/$replace/g;
#        #Logger->log("in $key replacing $match with $replace");
#    }
    
    my %session;

    $contents = $self->{carryover} . $contents;

    my @results = split(/\n/, $contents);
    if (chomp($contents)) {
        $self->{carryover} = '';
    } else {
        $self->{carryover} = pop @results;  # the last item is partial CSV record
    }

    my $filter = POE::Filter::CSV->new( { binary => 1 }); # binary for crazy chars

    my $results_ref = $filter->get( [@results] );

    #Logger->log(Dumper($results_ref));


    #my $field = $self->{field};

    foreach $row (@$results_ref) {
        #print Dumper($row);
	#print "row[0]: $row->[0]\n";
    
	my $rec = $row->[0];
	if ($rec eq '$C') { # car class
	    $self->{class}{$row->[1]} = $row->[2];
	    #print "class: " . $self->{class}{$row->[1]}."\n";
	} elsif ($rec eq '$COMP') { # competitor
	    my $car      = $row->[1];
	    my $class    = $row->[3];
	    my $driver   = "$row->[4] $row->[5]";

	    $driver =~ s/\s*\(N\)//;
	    $driver =~ s/\s+jr\.*//i;   # get rid of Junior designator.  This should be done in UI.

	    $field{$car}{class}  = $self->{class}{$class};
	    $self->{field}{$car}{driver} = $driver;
	    #$field{$car}{driver} = $driver;
	    Logger->log("got a COMP record for driver: $driver in field: ".$self->{field}{$car}{driver});
	} elsif ($rec eq '$G') {  # order by position
	    my $pos  = $row->[1];
	    my $car  = $row->[2];
	    my $laps = $row->[3];
	    Logger->log("got a G record for car: $car  pos: $pos");

#	    Logger->log(Dumper($self->{order}));
	    if ($self->{order}->[$pos-1] ne $car) { # car is not yet tracked or position change
		#@{$self->{order} = grep(!/^$car$/, @{$self->{order}});
		@{$self->{order}} = # need to catch undef and '0'
                   grep { !defined($_) or !/^$car$/ } @{$self->{order}};

		if (!defined($self->{order}->[$pos-1])) {
		    $self->{order}->[$pos-1] = $car;  # splice did not work in empty array
		} else {
	            splice(@{$self->{order}}, $pos-1, 0, $car); # insert
		}
	    }
	    
	    if ((!defined($self->{field}{$car}{laps})) or
	        ($self->{field}{$car}{laps} < $laps)) {
                $self->{field}{$car}{laps} = $laps;
	    }
		
	    $self->{field}{$car}{last_lap} = 
		             RaceControl::Utils::time_to_dec($row->[4]);
	} elsif ($rec eq '$H') {  # order by time
	    my $pos      = $row->[1];
	    my $car      = $row->[2];
	    my $bl_num   = $row->[3];
	    my $best_lap = $row->[4];
	    $self->{field}{$car}{bl_num}  = $bl_num;
	    $self->{field}{$car}{best_lap} = 
		              RaceControl::Utils::time_to_dec($best_lap);
	    Logger->log("got a H (best lap) record for car: $car lap: $bl_num  time: ".$self->{field}{$car}{best_lap});
	} elsif ($rec eq '$F') { # time ticker and flag info
	    my $flag = $row->[5]; 
	    $flag =~ s/\s+$//;
            $session{flag} = $flag;
	    Logger->log('got F rec');
        } elsif ($rec eq '$B') {
	    $session{event} = $row->[2];
        } else {
	    Logger->log("skip $row->[0]");	    
        }
    }

    # create %session from tracked info
    #Logger->log(Dumper($self->{order}));
    for (my $cnt=0; $cnt < scalar(@{$self->{order}}); $cnt++) {

	my $car = $self->{order}->[$cnt];

	if ((!defined($car)) or
	    (!defined($self->{field}{$car}{driver}))) {
            next;
        }

	$session{positions}[$cnt]{car} = $car;
        $session{positions}[$cnt]{id}  = $car;
	$session{positions}[$cnt]{position} = $cnt+1;
	$session{positions}[$cnt]{driver}   = $self->{field}{$car}{driver};
	$session{positions}[$cnt]{class}    = $self->{field}{$car}{class};
        $session{positions}[$cnt]{last_lap} = $self->{field}{$car}{last_lap};
	$session{positions}[$cnt]{best_lap} = $self->{field}{$car}{best_lap};
	$session{positions}[$cnt]{bl_num}   = $self->{field}{$car}{bl_num};
	$session{positions}[$cnt]{status}   = 'Run';  # maybe I will find this

    }

    # hardcode some stuff for now
    $session{control_message} = '';

    #Logger->log('session: '.Dumper(%session));

    return %session;
}
