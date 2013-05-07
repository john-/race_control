package RACEMONITORLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";
use RaceControl::Utils;

use POE::Filter::CSV;
#use HTML::Clean;
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

    $self->{field} = \();  # Store car/drive info
    $self->{order} = [];   # Running order
    $self->{class} = ();   # Car class information
    $self->{carryover} = '';   # from previous time called
    
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
    
    #my %session;

    $contents = $self->{carryover} . $contents;

    my @results = split(/\n/, $contents);
    if (chomp($contents)) {
        $self->{carryover} = '';
    } else {
        $self->{carryover} = pop @results;  # the last item is partial CSV record
    }

    my $filter = POE::Filter::CSV->new();

    my $arrayref = $filter->get( [@results] );

    print Dumper($arrayref);




    return %session;
}
