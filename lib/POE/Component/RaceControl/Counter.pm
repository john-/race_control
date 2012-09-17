package POE::Component::Counter;

use strict;
use warnings;

use POE;
use POE::Wheel::ReadWrite;

use IO::File;
use DBI;
use Net::GPSD;
use POSIX;
use Tie::IxHash;

use Carp;

use Data::Dumper;

sub new {
    my $package = shift;

    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;



    POE::Session->create(
        object_states => [
            $self => {
	        _start         => '_cntr_start',
		_stop          => '_cntr_stop',
		cntr_dev_init  => '_cntr_dev_init',
	        cntr_got_port  => '_cntr_got_port',
	        cntr_got_error => '_cntr_got_error',
		cntr_log_freq  => '_cntr_log_freq',

		log_mode       => 'log_mode',

		scan_simulator => '_cntr_scan_simulator',

		test_function => '_test_function',

	    }

        ]

    );

    return $self;
}

sub _cntr_start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    Logger->log({level => 'error',message => "in _cntr_start"});

    #print "TEMP HACKED FOR WINDOWS\n";
    $kernel->alias_set("$self");

    my $dbargs = {AutoCommit => 1,
                  PrintError => 1};

    my $db = $self->{config}{database}{name};
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db","","",$dbargs);

    $self->{log_insert} = $dbh->prepare("insert into cntrlog (frequency, source, lat, lon, alt) values (?, ?, ?, ?, ?)");
    # This SQL (or the underlying data schema) has a bug.  If a frequency
    # appears more than once in freqs database, then the grouping is inaccurate
    my $summary = $self->{config}{counter}{summary};
    $self->{log_summary} = $dbh->prepare($summary);
    my $detail = $self->{config}{counter}{detail};
    $self->{log_detail} = $dbh->prepare($detail);

    $self->{gps} = Net::GPSD->new;

    $kernel->yield( 'cntr_dev_init' );

}

sub _cntr_dev_init {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    my $device = $self->{config}{counter}{device};

    if (! -e $device) { 
        Logger->log({level => 'error',message => "$device does not exist"});
        $kernel->delay('cntr_dev_init' => 
                            $self->{config}{counter}{retry_rate});
	return;
    }

    $self->{fh} = new IO::File;
    if (!$self->{fh}->open("+<$device")) {
	undef $self->{fh};
        Logger->log({level => 'error',message => "Unable to open $device"});
        $kernel->delay('cntr_dev_init' => 
                            $self->{config}{counter}{retry_rate});
	return;
         #confess("Unable to open $device RW: $!\n");
    }

    _set_speed($self->{fh}, $self->{config}{counter}{baud});

    $self->{counter} = POE::Wheel::ReadWrite->new(
        Handle => $self->{fh},
        Filter => POE::Filter::Line->new(
#            InputLiteral  => "\x0A",    # Received line endings.
#            InputLiteral  => "\x0D\x0A",    # Received line endings.
            OutputLiteral => "\x0D",        # Sent line endings.
        ),
        InputEvent => 'cntr_got_port',
        ErrorEvent => 'cntr_got_port',
    );

    #$kernel->yield( 'scan_simulator' );
    
}

sub _set_speed ($$) {
    my $fh = shift || die;
    my $speed = shift;

    my $termios = POSIX::Termios->new() || die;
    $termios->getattr(fileno($fh)) || die "$!";

    # The handshake is done at 9600
    eval("\$termios->setispeed(&POSIX::B$speed)") || die "$!";
    eval("\$termios->setospeed(&POSIX::B$speed)") || die "$!";

    # Enable the receiver and set local mode...
    my $c_cflag = $termios->getcflag();
    #$c_cflag |= (CLOCAL | CREAD);

    # data format: 8N1
    $c_cflag &= ~(PARENB);      # disable parity bit
    $c_cflag &= ~(CSTOPB);      # set 1 stop bit
    #$c_cflag &= ~(CSIZE);       # Mask the character size bits
    $c_cflag |=  (CS8);         # Select 8 data bits

    # Disable hardware flow control
    #$c_cflag &= ~(CRTSCTS);

    $termios->setcflag( $c_cflag );

    $termios->setattr(fileno($fh), &POSIX::TCSANOW);
}


sub _cntr_got_port {
    my ($kernel, $data) = @_[ KERNEL, ARG0 ];

    print "raw: |$data|\n";

    if ( $data =~ /RF(\d\d\d\d\d\d\d\d)(\d\d)/ ) {
	#print "freq: $1.$2 $3\n";
	#my $dec = $2 / 10000;
	#print "initial dec: $dec\n";
	#if ($3 == 50) {  # nothing besides 50 has presented itself
	#    print "int of dec * 100: ".int($dec*100)."\n";
	#    if ( int($dec * 100) eq ($dec * 100) ) 
        #        { $dec = $dec + 0.00125 }
        #    else
	#        { $dec = $dec - 0.00125 }  
	#}

	#my $freq = $1 + $dec;
	my $freq = $1 / 10000;
        #print "freq: $freq\n";
	$kernel->yield( 'cntr_log_freq', $freq );
	
    } elsif ( $data ne '' ) {
	print "not sure what this is: $data\n";
    }

    #print "-----\n";
}

sub _cntr_log_freq {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];
    
    my ($lat, $lon, $alt);
    my $gps = $self->{gps};
    my $loc = $gps->get;
    if ($loc->fix) {
	$lat  = $loc->lat;
	$lon = $loc->lon;
	$alt  = $loc->alt;
    }

    $self->{log_insert}->execute($_[ARG0], 'counter', $lat, $lon, $alt);
    $kernel->post('ui', 'counter_update', $_[ARG0]);

}

sub _cntr_got_error {
    Logger->log('error occured communicating with counter');

}

sub _cntr_stop {
    print "should stop db stuff here\n";

    $_[OBJECT]->{log_insert}->finish();
}

sub get_freqs {
    my $self = shift;

    $self->{log_summary}->execute();

    return $self->{log_summary}->fetchall_arrayref( {} );
}

sub get_freq_detail {
    my ($self, $freq) = @_;
    
    $self->{log_detail}->execute( $freq );

    return $self->{log_detail}->fetchall_arrayref( {} );
}

sub _test_function {
    return '3';
}

# this doesn't appear to be required as the counter seems to do the
# right think as long as it is configured for Reaction Tune / AOR
sub log_mode {
    my $self = shift;

    #my $cmd = sprintf('%u%u%u%u%u%u%u', 
    #                           0xFE, 0xFE, 0x9E, 0xE0, 0x06, 0x00, 0xFD);

    my $cmd = pack('C7',0xFE, 0xFE, 0x9E, 0xE0, 0x06, 0x00, 0xFD);
    #print "cmd: |$cmd|\n:";

    print "length: ".length($cmd) . "\n";
    my @undo = unpack('C7', $cmd);

    print "unpacked:\n";
    foreach (@undo) { print sprintf("%x\n", $_); }

    $self->{counter}->put( 'wacky command' );
    #$poe_kernel->call("$self", 'test_function');
}

sub _cntr_scan_simulator {
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];

    my @freqs = ( 467.15, 466.48, 467.095 );
#    my @freqs = ( 467.15, 466.48, 467.095, 464.3625, 464.545, 466.87,
#                  466.93, 467.3, 464.675, 467.53, 467.3125, 467.475 );
    my $freq = $freqs[int(rand($#freqs))];

    #print "simulated freq: $freq\n";
    #$kernel->yield( 'cntr_log_freq', $freq );
    $kernel->delay_set ( 'scan_simulator', 2 );

    

}

1;
