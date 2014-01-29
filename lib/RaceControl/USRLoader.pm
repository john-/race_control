package USRLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;

use HTML::Clean;
use HTML::TableExtract;
use Data::Dumper;
use POE::Component::Logger;

#@ISA = (StateLoader);

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    return $self;
}

my @cleanups = (
    [ best_speed => qr{\+}        ], # sometimes there is a "+" at end
    [ status     => qr{P},  'Pit' ],
    [ status     => qr{R},  'Ret' ],
    [ status     => qr{E},  'Ret' ],
    [ status     => qr{\ }, 'Run' ], # default is blank
    );

sub get_state {
    my ($self, $contents) = @_;

    #my $contents = $self->_get_contents();
    my $h = new HTML::Clean(\$contents);

    $h->strip();
    my $data = $h->data();

    my $html = $$data;

    $html =~ s/\n//g;

    my %session;

    ($session{time})      = $html =~ /Session time:.+?(\d\d\:\d\d\:\d\d)/;
    ($session{remaining}) = $html =~ /Remaining time:.+?(\d\d\:\d\d\:\d\d)/;

    # session-type-race flag-green

    ($session{event}, $session{flag}) = $html =~ /session-type-(\w+) flag-(\w+)/;
    
    $session{event} = ucfirst($session{event});
    $session{flag}  = ucfirst($session{flag});
    
    #Logger->log("time: $time  remaining: $remaining  flag: $flag event: $event");
   
    #$html =~ s/(.*): (\w+)\&nbsp\;(.+?)\&nbsp(\(\.+)/\|$1\| \|$2\| \|$3\|/;
    $html =~ s/\&nbsp\;//g;  # get rid of the test of the non breaking spaces

    #Logger->log($html);

    %tablemap = %{$self->{config}{session}{series}{$self->{series}}{tablemap}};

    # headers which determine what table is extracted
    # these are from HTML <table> section
    my @headers = keys %tablemap;

    # we had to use '\' in hash keys.  However, in html they need to be ' '
    foreach (@headers) {
	s/\|/ /g;
    }

    #Logger->log( {level => 'warning', 
    #        message =>"headers: ".Dumper(@headers).'  :'.$self->{series} });

    my $te_pos = HTML::TableExtract->new( headers => [@headers],
                                           );
    $te_pos->parse($html);

    if (!$te_pos->tables()) {
        Logger->log( {level => 'alert', 
            message =>"Could NOT get the table with header info.  Check |$self->{series}|tablemap in race_control.conf" });
	return;
    }

    #Logger->log(Dumper($te_pos->rows));

    foreach $row (@{$te_pos->rows}) {
	my $idx = 0;
	my $position;
	foreach $col (@$row) {
	    my $lookup = $headers[$idx];
	    $lookup =~ s/ /\|/g;  # need to lookup using '|' as that is in key
	    $position->{$tablemap{$lookup}} = $col;
 	    $idx++;
	}

	push @{$session{positions}}, $position;
	#Logger->log(Dumper($position));
    }
    
    #Logger->log(Dumper(%session));

    # convert time from MM:SS to seconds and other clean up
    foreach (@{$session{positions}}) {
	# handle case where driver and model are in same column
	#if ($_->{driver} =~ /(.*)\n(.*)/) {
	#    Logger->log("Modified driver to seperate out model: $_->{driver}");
	#    ($_->{driver}, $_->{model}) = $_->{driver} =~ /(.*)\n(.*)/;
        #}
        #Logger->log("driver: |$_->{driver}|  model: |$_->{model}|");

	#$_->{driver} =~ s/ \//\//;  # some of the names have space before /

        foreach my $cleanup (@cleanups) {
	    my ($key, $match, $replace) = @$cleanup;

	    $_->{$key} =~ s/$match/$replace/g;
	    #Logger->log("in $key replacing $match with $replace");
	}

        $_->{last_lap} = RaceControl::Utils::time_to_dec($_->{last_lap});
        $_->{best_lap} = RaceControl::Utils::time_to_dec($_->{best_lap});

	# remove leading whitespace
	#$_->{class} =~ s/^\s+//;
	#$_->{model} =~ s/^\s+//;

	$_->{id} = $_->{car};  # as I recall, one series dups car numbers
	                       # needs to be unique (car is for ALMS)

	#if ($_->{status} eq 'P') {
	#    $_->{status} = 'Pit';
	#} elsif ($_->{status} eq 'R') {
	#    $_->{status} = 'Ret';
        #} elsif ($_->{status} eq 'E') {
	#    $_->{status} = 'Ret';
	#} elsif ($_->{status} eq ' ') {
	#    $_->{status} = 'Run';
	#} else {
	#    Logger->log("unknown status (ALMSLoader): |$_->{status}|");
	#}

	$_->{series} = $self->{series};
	#Logger->log(Dumper($_));
    }

    # One more space at the end
    Logger->log((join '| ',
                map "$_: |$session{$_}", qw/series event flag time/).'|');

    return %session;
}
