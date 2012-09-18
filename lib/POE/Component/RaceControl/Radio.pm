package POE::Component::Radio;

use strict;
use warnings;
use POE;
use POE::Wheel::ReadWrite;
use Symbol qw(gensym);
use Device::SerialPort;
use POE::Filter::Line;
#use POE::Component::IKC::Server;
use Tie::IxHash;
#use POSIX;
use Net::GPSD;

use DBI;
use POE qw( Component::EasyDBI ); # POE used for bandscope persistent storage

use Carp;

use IO::File;

use YAML::XS;

use Data::Dumper;

sub new {
    my $package = shift;

    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    POE::Session->create(
        object_states => [
	    $self => {
		_start            => '_radio_start',
		_stop             => '_radio_stop',
		radio_dev_init    => '_radio_dev_init',
		radio_got_port    => '_radio_got_port',
		radio_got_error   => '_radio_got_error',
		radio_cmd         => '_radio_cmd',
		radio_slow_bank_writer => '_radio_slow_bank_writer',
		connected         => 'connected',

		#ikc_server_init   => '_ikc_server_init',
		
		next_scope_block  => '_next_scope_block',
		next_scope_pass   => '_next_scope_pass',
		kick_scope        => '_kick_scope',
		get_scope_info    => 'get_scope_info',
		scope_info_returned => '_scope_info_returned',

		resync_scan_info => 'resync_scan_info',

		scan              => 'scan',
		search            => 'search',
		scope             => 'scope',

		store             => 'store',
		
		pass_info_inserted   => 'pass_info_inserted',
		scope_datum_inserted => 'scope_datum_inserted',
		
		scan_simulator    => 'scan_simulator',

		#sig_child         => 'sig_child',
            }
        ],
    );

    return $self;
}

sub get_info_struct {
    my ($self, $qry) = @_;

    Logger->log("qry: $qry");

    #my $sql = 'select distinct freqs.frequency, freqs.designator from freqs,radiolog where ' . $qry;
    #my $sql = 'select * from freqs where ' . $qry;

    Logger->log("qry: $qry");
    
    my @matches = @{ $self->{dbh}->selectall_arrayref( $qry, { Slice => {} } ) };
    return @matches;
}

sub get_info {
    my ($self, $qry) = @_;

    my @matches = $self->get_info_struct($qry);

    my $result = Dump(\@matches);

    return $result;
}

sub set_info {
    my ($self, $yaml) = @_;
		
    Logger->log({level => 'critical', message => 'SET_INFO NOT IMPLEMENTED.  TO BE REMOVED IN LUE OF SEPERATE DB GRID APP (see freq_gui)'});

    my $updates;
    eval { $updates = Load($yaml) };
    return $@ if $@;
    
    my $sth = $self->{dbh}->prepare('select count(*) from freqs where frequency = ?');

    my $ID;
    for my $update (@$updates) {
	$sth->execute( $update->{frequency});

	my @row = @{ $sth->fetchall_arrayref() };

	my $cnt = $row[0];
	print "count: $cnt\n";
	print Dumper(@row);
	
	
	#if (defined($ID = $update->{ID_do_not_touch})) {
	#    print "changed record with ID: $ID\n";
	#    delete($update->{ID_do_not_touch});
	#    ${$heap->{freqs}}[$ID] = $update;
        #} else {
  	#    print "new record added\n";
	#    push @{$heap->{freqs}}, $update;
   	#}
    }

    #$kernel->yield( 'save' );
}

sub write_bank {
    my ($self, $qry, $bank, $label) = @_;

    my @matches = $self->get_info_struct( $qry );
    
    #foreach (@matches) { print aor_freq($_->{frequency}) . "\n" };
    my @aor_lines = aor_write_format( \@matches, $bank, $label );

    $poe_kernel->call( $self->{alias}, 'radio_slow_bank_writer', \@aor_lines );

}

sub _radio_slow_bank_writer {
    my ($kernel, $aor_lines) = @_[ KERNEL, ARG0 ];

    Logger->log(Dumper($aor_lines));
    my $delay = 0;
    foreach (@$aor_lines) { 
	$kernel->delay_add( radio_cmd => $delay, $_  );
	$delay = $delay + 0.75;
    }
}


sub _radio_start {
    my ( $kernel, $self, $sender, $heap ) = @_[ KERNEL, OBJECT, SENDER, HEAP ];

    Logger->log('in _radio_start');

    #$kernel->alias_set("$self");
    $kernel->alias_set($self->{alias});

    #my @tmp_alias = $kernel->alias_list($_[SESSION]);
    #print "session thinks alias list is @tmp_alias\n";

    $self->{caller} = $sender->ID;

    $self->{scanned_freq} = '';

    #$kernel->yield( 'scan_simulator' );

    $self->{connected} = 0; # assume not connected

    # init frequeny db

    my $dbargs = {AutoCommit => 1,
                  PrintError => 1};

    my $db = $self->{config}{database}{name};
    # not sure what prep'd statements I need.  store the dbh for now.
    $self->{dbh} = DBI->connect("dbi:SQLite:dbname=$db","","",$dbargs);

    $self->{log_insert} = $self->{dbh}->prepare("insert into radiolog (frequency, source, groups) values (?, ?, ?)");

    # set up session to handle persistent storage of bandscope data
    # using POE for this data as volume of data would benifet from
    # non-blocking approach.  Should go back and change method
    # for radiolog updates to be consistent
    my $scope_db = $self->{config}{database}{scope};
    POE::Component::EasyDBI->spawn(
        alias       => 'scope_storage',
        dsn         => "dbi:SQLite:dbname=$scope_db",
        username    => '',
        password    => '',
        options     => {
            AutoCommit => 1,
            PrintError => 1,
        },
    );

    # if GPS is not connected retry will occur
    # each time client attempts to get a new location
    $self->{gps} = Net::GPSD->new;

    $kernel->yield( 'radio_dev_init' );
}

# Detect the CHLD signal as each of our children exits.
sub sig_child {
  my ($heap, $sig, $pid, $exit_val) = @_[HEAP, ARG0, ARG1, ARG2];
  my $details = delete $heap->{$pid};

  Logger->log("$$: Child $pid exited");
}

sub _radio_dev_init {
    my ( $kernel, $heap, $self, $sender ) = @_[ KERNEL, HEAP, OBJECT, SENDER ];

    my $radio_dev = $self->{config}{radio}{$self->{alias}}{device};

    if (! -e $radio_dev) { 
        Logger->log({level => 'error',message => "$radio_dev does not exist"});
        $kernel->delay('radio_dev_init' => 
                            $self->{config}{radio}{$self->{alias}}{retry_rate});
	return;
    }

    $self->{fh} = new IO::File;
    if (!$self->{fh}->open("+<$radio_dev")) {
	undef $self->{fh};
        Logger->log({level => 'error',message => "Unable to open $radio_dev"});
        $kernel->delay('radio_dev_init' => 
                            $self->{config}{radio}{$self->{alias}}{retry_rate});
	return;

        #Logger->log({level => 'error', message => "Unable to open $radio_dev RW: $!"});
        #confess("Unable to open $radio_dev RW: $!\n");
    }

    #print "UNCOMMENT FOR LINUX\n";
    set_speed($self->{fh}, $self->{config}{radio}{$self->{alias}}{baud});

    # Start interacting with the scanner.

    $self->{scanner} = POE::Wheel::ReadWrite->new(
        Handle => $self->{fh},
        Filter => POE::Filter::Line->new(
            InputLiteral  => "\x0D\x0A",    # Received line endings.
            OutputLiteral => "\x0D",        # Sent line endings.
        ),
        InputEvent => "radio_got_port",
        ErrorEvent => "radio_got_error",
    );

    
    # test to make sure radio is interacting OK

    if (! $self->{connected}) { 
	my $alias = $self->{alias};
        $poe_kernel->call( $alias, 'radio_cmd', 'VR' );

        Logger->log({level => 'error',
		     message => "not connected to $alias ($radio_dev)"});
        $kernel->delay('radio_dev_init' => 
                            $self->{config}{radio}{$self->{alias}}{retry_rate});
	return;
    }






}

sub _radio_got_port {
    my ( $kernel, $heap, $self, $data ) = @_[ KERNEL, HEAP, OBJECT, ARG0 ];

    $_ = $data;
    #Logger->log({level => 'debug', message => "INCOMING: ($_)"});

    my ($event, $info, $info2);
    # LC000 MXg04 RF0027015000 (scan stops on freq)
    # LC009 SRa RF064475000 (this comes back when search stops on freq)
    if (/LC\d\d\d \w+ RF(.*)/) {
	Logger->log("lock: freq: ($1)");
	$event = 'tune';
	$info = 'lock';
	$self->{scanned_freq} = $1;
	#Logger->log("storing frequency on heap: $self->{scanned_freq}");
	my $freq = human_freq( $self->{scanned_freq} );

	my $freq_info_ref = $self->get_freq_info($freq);
	

	# send event to UI
        $kernel->post( $self->{caller}, 
                       $event,
		       $self->{alias},
		       $info,
		       $freq_info_ref );

        # TODO: Need a default mode.  Better yet, interigate radio to get it
        #Logger->log("freq in radio: $freq   mode: $self->{mode}");
	# store scanned/searched freq in db
        $self->{log_insert}->execute($freq, 'radio', 
             sprintf('%s %s', 
                $self->{mode}, $self->{config}{radio}{venue}) );



        # if there is store_target defined and not us, use it
        my $store_target = $self->{config}{radio}{store_target};
        if (($store_target ne $self->{alias}) and
            ($store_target ne 'NONE') and
            ($self->{mode} eq 'search')) {
	    $kernel->post( $store_target, 'store', $freq);
        }

    } elsif (/LC%(\d\d\d) \w+/) {                 # LC%000 MXg03 
	                                          # LC%023 SRa
	# seems like when scan groups are used this gets fired
	# off when crossing scan banks
	#Logger->log("transmission ended");
	$event = 'scanning';
	$info  = '';
	#Logger->log("about to call scanning event.  info: $info  info2: $info2");
        $kernel->post( $self->{caller}, $event, $self->{alias}, $info, $info2 );
    } elsif (/DS(\d\d\d\d):(.{16}) (.{16})/) {# DS0447:2222222422222222 2229722982222222      
        #Logger->log("bandscope data: $_");
	my @block = reverse split(//,$3);
	push @block, reverse split(//,$2);

	my $base_pos = $1;  # where DS line starts
	my $center_pos = $self->{config}{race_gui}{bandscope}{center_pos};
	my $span = $self->{config}{race_gui}{bandscope}{span};
	my $step_size = $self->{config}{race_gui}{bandscope}{step_size};
	my $steps = ($span*1000) / $step_size;
	my $min_pos = $center_pos - ($steps / 2);

	my $center_freq = $self->{scope}{center_freq};
        my $min_freq = $center_freq - ($span / 2);

	#Logger->log(sprintf('base_pos: %d center_pos: %d steps: %d min_pos: %d min_freq: %d',
	#		    $base_pos, $center_pos, $steps, $min_pos, $min_freq));
	
	for (my $step=0; $step<=31; ++$step) {
	    # absolute position
	    my $abs_pos = ($base_pos - 31) + $step;
	    my $strength = hex($block[$step]);
	    if ( ($abs_pos < $min_pos) or ($abs_pos > ($min_pos+$steps)) or
                  ($strength <= 2) ) {
		#Logger->log("Skipping $abs_pos");
		next;
  	    }
   	    $abs_pos = $abs_pos - $min_pos;  # make it zero based
	    # calc frequency
	    my $freq = $min_freq + $abs_pos * ($step_size/1000);
	    # send event for ui
	    #Logger->log(sprintf('abs_pos: %d step: %d freq: %f  strength: %s',
	    #			$abs_pos, $step, $freq, $strength));
	    my %datum_info = (
		frequency => $freq,
		strength  => $strength,
		passid    => $self->{scope}{current_passid},
		radio     => $self->{alias},
		time      => gmtime(time()),
   	    );
            $kernel->post( $self->{caller}, 'scope_datum' => \%datum_info );

	    # send event to write to DB
            $kernel->post( 'scope_storage', 
	        insert => {
	            sql => 'insert into scopelog (frequency, strength, passid) values (?,?,?)',
	            placeholders => [ sprintf('%.2f',$freq), $strength, $self->{scope}{current_passid} ],
	            event => 'scope_datum_inserted',
	    },
    );
	    
	}
	
	if ($1 eq '0031') {  # end of stream
	    $kernel->yield( 'next_scope_block' );
        }
    } elsif (/BM ([a-jA-J\-]+)$/) { # BM ---------------fg---
	my $banks = $1;
	$banks =~ s/-//g;
	Logger->log("linked banks on $self->{alias} |$banks|");
	foreach (split //, $banks) {
            Logger->log("setting bank $_ status to pending");
	    $self->{banks}{$_}{status} = 'pending';
        }
	$self->{banks}{$self->{config}{radio}{$self->{alias}}{scan_bank}}{status} = 'pending';   # in any case, push the bank being scanned (takes care of condition where there is to scan linked scan group defined
    } elsif (/MX(\w)(\d\d) MP(\d) RF(.+) ST(.+) AU(\d) MD(\d) AT(\d) TM(.*)/) {# MXf04 MP0 RF0459387500 ST012500 AU1 MD1 AT0 TM3 Primary (i
	# response to command to dump stored freqs

	# TODO: this gets hit when RX command gets sent and user
        # has not done a resync.  Might not matter even
	# though error gets thrown in here.

        Logger->log("bank: $1 slot: $2 label: $9 sizeofbank: $self->{banks}{$1}{max_slot}");
	$self->{banks}{$1}{$2}{pass} = $3;
	$self->{banks}{$1}{$2}{freq} = aor_freq($4);
	$self->{banks}{$1}{$2}{label} = $9;
	
	# This section is copy/pasted in next record type
	if ($self->{banks}{$1}{max_slot} == $2) {
	    $self->{banks}{$1}{status} = 'loaded';
	    Logger->log("completed loading bank $1");
        } else {
	    $self->{banks}{$1}{status} = 'dumping';
	}

	# store current slot as it may be the last if
	# no more after it
        $self->{banks}{$1}{last_slot} = $2

	#my $mod = ($2+1)%10;
	#Logger->log("mod: $mod");
	#if (($2+1) % 10 == 0) {
	#    $kernel->yield('resync_scan_info');
	#}

    # this occurs when you request a dump of a scan bank and the memory
    # slot is empty
    } elsif (/MX(\w)(\d\d) ---/) {   # MXg26 ---
	Logger->log("blank slot at bank: $1 slot: $2");
	if ($self->{banks}{$1}{max_slot} == $2) {
	    $self->{banks}{$1}{status} = 'loaded';
	    Logger->log("completed loading bank $1");
        } else {
	    $self->{banks}{$1}{status} = 'dumping';
	}
	#$self->{banks}{$1}{status} = 'loaded';
    # this is in response to a bank size request
    } elsif (/MW (\w):(\d\d) (\w):(\d\d)/) { # MW F:10 f:90
	# we will only store max num slots for those banks scanner is scanning
	# slots are zero based
	if ($self->{banks}{$1}) {
	    $self->{banks}{$1}{max_slot} = $2-1;
            Logger->log("size of $1 is $2");
	}
	if ($self->{banks}{$3}) {
	    $self->{banks}{$3}{max_slot} = $4-1;
            Logger->log("size of $3 is $4");
	}
    } elsif (/VR(\w+)/) {
	$self->{connected} = 1;
	Logger->log({level => 'warning', 
                     message => "connected to $self->{alias} version $1"});
    } else {
	Logger->log({level => 'warning', message => "unparsed: ($_)"});
	$event = 'TBD2';
	$info  = $1;
    }

    if ($self->{log_sink}) {
	#Logger->log("sending item to log: $self->{log_sink}");
	# this may need to provide the alias of the radio that send info
        $kernel->post( $self->{caller}, $self->{log_sink}, $_ );
    } else {
	#Logger->log('log_sink NOT configured');
    }   
}


sub store {
    my ($kernel, $self, $freq) = @_[ KERNEL, OBJECT, ARG0 ];

    Logger->log("in store logic on $self->{alias}");

    # on $store_target do $self->store_freq;

    my $store_bank = $self->{config}{radio}{$self->{alias}}{store_bank};

    #Logger->log("before: ".Dumper($self->{banks}));
    if (!exists $self->{banks}{$store_bank}{status}) {
	return;
    }
    if  ($self->{banks}{$store_bank}{status} ne 'loaded') {
        return;
    }

    Logger->log("store bank $store_bank has been loaded on $self->{alias}");

    if (freq_being_scanned($freq)) {
	Logger->log("Frequency $freq already being scanned");
	return;
    }

    my $next_slot = $self->{banks}{$store_bank}{last_slot} + 1;

    Logger->log("to be saved to store_bank: $store_bank  next_slot: $next_slot");

    if ($next_slot gt $self->{banks}{$store_bank}{max_slot}) {
  	Logger->log("could not write to $self->{alias} bank $store_bank as we have used all $next_slot slots");
	return;

    }

    $self->{banks}{$store_bank}{last_slot} = $next_slot;
    $self->{banks}{$store_bank}{$next_slot}{freq} = $freq;
		
    # stop scanning before write (per manual)
    my $mode = $self->{mode};
    if ($mode ne 'hold') { $self->hold };

    # write command
    # MX command.   Probably a function to reuse that does this
    my $cmd = sprintf ( 'MX%1s%02d MP0 RF%10s AU1 TM%-12.12s', 
	    $store_bank, $next_slot, aor_freq($freq), 'Searched' );
    Logger->log("about to execute: $cmd");
    #$kernel->yield( 'radio_cmd', $cmd);

    # start scanning if it was before write
    if ($mode ne $self->{mode}) { $self->$mode }
}


sub get_freq_info {
    my ($self, $freq) = @_;

    # TODO: Test case where more than one record is returned for a given freq

    Logger->log("freq in get_freq_info: $freq");

    # return info for a single occurance of the freq
    my $year = (localtime)[5] + 1900;
    my @freq_info = $self->get_info_struct( "select * from freqs where frequency = $freq and strftime('%Y', time) = \'$year\' order by time desc" );
    if (scalar @freq_info gt 1) {
        #@freq_info = ( $freq_info[0] ); # use the first one if more than one
        Logger->log("Radio returned more than one freq for $freq.  Picked newest");
    } elsif (!@freq_info) { push @freq_info, { frequency => $freq } }

    #Logger->log(Dumper(@freq_info));

    return \%{$freq_info[0]};
}

sub freq_being_scanned {
    my ($self, $freq) = @_;

     #$self->{banks}{$1}{$2}{pass} = $3;
     #$self->{banks}{$1}{$2}{freq} = aor_freq($4);
     #$self->{banks}{$1}{$2}{label} = $9;

    my $being_scanned;
    Dumper($self->{banks});
    my @banks = keys %{$self->{banks}};
    foreach my $bank (@banks) {
	my @slots = keys %{$self->{banks}{$bank}};
	foreach my $slot (@slots) {
	    if ($self->{banks}{$bank}{$slot}{freq} == $freq) {
		$being_scanned = 1;
	    }
	}
    }

    return $being_scanned;
}

sub scope_datum_inserted {
    my $result = $_[ ARG0 ];

    #if (grep /720.00/, @{$result->{placeholders}}) {
	#Logger->log(Dumper(@{$result->{placeholders}}))
    #}

    if (defined $result->{error}) {
	my $error        = $result->{error};
	my @placeholders = @{$result->{placeholders}};
	if ($error =~ !/.*columns frequency, passid are not unique.*/) {
	    Logger->log("Error writing datum to table: $error  placeholders: @placeholders");
	} else {
	    # because center freq increase by exactly span width, we
	    # hit the freq multiple times
	    Logger->log({level => 'info', 
               message => "Freq is at boundry"});
	}
    } else {
	#Logger->log('Datum written to table');
    }
    

}

sub _next_scope_block {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    my $center   = $self->{scope}{center_freq};
    my $min_freq = $self->{scope}{min_freq};
    my $max_freq = $self->{scope}{max_freq};

    my $span = $self->{config}{race_gui}{bandscope}{span};

    $center = $center + $span;

    if ($center > $max_freq) {
	$center = $min_freq + ($span/2);
        $kernel->yield( 'next_scope_pass' );
        $poe_kernel->post( 'booth' => 'say' => "Frequency analyzer back to $min_freq megahertz" );
    }

    $self->{scope}{center_freq} = $center;

    $kernel->yield( 'kick_scope' );
}

sub _next_scope_pass {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    my ($lat, $lon, $alt);
    my $gps = $self->{gps};
    Logger->log(Dumper($gps));
    #my $loc = $gps->get;
    #if ($loc->fix) {
    #	$lat  = $loc->lat;
    #	$lon = $loc->lon;
    #	$alt  = $loc->alt;
    #}

    $kernel->post( 'scope_storage', 
	   insert => {
	       sql => 'insert into scopepass (lat, lon, alt) values (?,?,?)',
	       placeholders => [ $lat, $lon, $alt ],
	       last_insert_id => { 
                   field => 'passid',
                   table => 'scopepass',
               },
	       event => 'pass_info_inserted',
	   },
    );


}

sub _kick_scope {
    my ($kernel, $self, $first_time) = @_[ KERNEL, OBJECT, ARG0 ];


    my $center = $self->{scope}{center_freq};

    $kernel->yield( 'radio_cmd', sprintf('CF%f', $center) ); # also puts radio into bandscope mode

    if (defined $first_time) {

        my $span = $self->{config}{race_gui}{bandscope}{span};
        my $spanparm;
        if ($span == 10) {
	    $spanparm = 1;
        } else {
            Logger->log({level => 'error', 
                   message => "Span defined (scope): $span"});
            return;
        }
        $kernel->delay( 'radio_cmd' => 2, sprintf('SW%s', $spanparm) );
    }



    $kernel->delay_add( 'radio_cmd' => 10, 'DS'  );
}

sub _radio_got_error {
    my $self = $_[OBJECT];

    #$heap->{console}->put("$_[ARG0] error $_[ARG1]: $_[ARG2]");
    #$heap->{console}->put("bye!");
    my $message =  "error writing to port $self->{config}{radio}{$self->{alias}}{device} for $self->{alias}!";
    Logger->log({level => 'error', message => $message});


    #delete $heap->{console};
    delete $self->{scanner};
}

sub _radio_stop {

    $_[OBJECT]->{log_insert}->finish();

    $_[KERNEL]->post( 'scope_storage' => 'commit' );
    $_[KERNEL]->post( 'scope_storage' => 'shutdown' );

}

sub _radio_cmd {
    my ( $self, $cmd, $arg ) = @_[ OBJECT, ARG0, ARG1 ];

    Logger->log("radio received cmd: $cmd");

    if (exists $self->{scanner}) {
        $self->{scanner}->put($cmd);
    } else {
	my $message = "scanner wheel does not exist for $self->{alias}!";
	Logger->log({level => 'warning', message => $message});
    }

    # Clearing $! after $serial_port_wheel->put() seems to work around
    # an issue in Device::SerialPort 1.000_002.

    $! = 0;
}

sub scan {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    my $bank = $self->{config}{radio}{$self->{alias}}{scan_bank};
    Logger->log({level => 'info', 
               message => "radio told to scan bank $bank"});
    $kernel->call( $self->{alias}, 'radio_cmd', sprintf('MS%s', $bank) );
    $self->{mode} = 'scan';
    $kernel->post( $self->{caller}, 'scanning' => $self->{alias} );
}

sub search {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    my $bank = $self->{config}{radio}{$self->{alias}}{search_bank};
    Logger->log({level => 'info', 
               message => "radio told to search bank $bank"});
    $kernel->call( $self->{alias}, 'radio_cmd', sprintf('SS%s', $bank) );
    $self->{mode} = 'search';
    $kernel->post( $self->{caller}, 'searching' => $self->{alias} );
}

sub scope {
    my ( $kernel, $self, $args) = @_[ KERNEL, OBJECT, ARG0 ];

    #Logger->log(Dumper($args));

    if ( (!defined($args->{MinFreq})) or (!defined($args->{MaxFreq})) ) {
        return;  # user selected scope button but did not asked to Run
    }

    my $minfreq = $args->{MinFreq};
    my $maxfreq = $args->{MaxFreq};

    #my $bank = $self->{config}{radio}{$self->{alias}}{search_bank};
    Logger->log({level => 'info', 
               message => "radio told to enter bandscope.  minfreq: $minfreq maxfreq: $maxfreq"});

    my $span = $self->{config}{race_gui}{bandscope}{span};

    my $center = $minfreq + ($span/2);
    $self->{scope}{center_freq} = $center;
    $self->{scope}{min_freq}    = $minfreq;
    $self->{scope}{max_freq}    = $maxfreq;

    # submit request for new pass entry on db and set property
    $kernel->yield( 'next_scope_pass' );

    # send commands to scope to enter scope mode
    $kernel->yield( 'kick_scope', 'Yes!' );

    $self->{mode} = 'scope';
    $kernel->post( $self->{caller}, 'scoping' => $self->{alias} );
    #print Dumper($poe_kernel->get_active_session());
}

sub pass_info_inserted {
    my ($self, $response) = @_[ OBJECT, ARG0 ];
    Logger->log("inserted new pass: $response->{insert_id}");
    $self->{scope}{current_passid} = $response->{insert_id};
}

sub get_scope_info {
    my ( $kernel, $self, $args) = @_[ KERNEL, OBJECT, ARG0 ];

    #Logger->log(Dumper($args));

    if ( (!defined($args->{MinFreq})) or (!defined($args->{MaxFreq})) ) {
        return;  # user selected scope button but did not asked to Render
    }

    my $minfreq = $args->{MinFreq};
    my $maxfreq = $args->{MaxFreq};

    # ugh.  Not sure why gui control can't pass '0' instead of ''.
    if ($minfreq eq '') {$minfreq = 0}
    
    Logger->log({level => 'info', message => "Asked to get scope info"});

    $kernel->post( 'scope_storage', 
	   arrayhash => {
	       #sql => 'select * from scopelog',
	       sql => 'select frequency, strength, passid, time from scopelog where frequency >= ? and frequency <= ?',
	       placeholders => [ $minfreq, $maxfreq ],
	       event => 'scope_info_returned',
	   }
    );
}

sub _scope_info_returned {
    my ($kernel, $self, $result) = @_[ KERNEL, OBJECT, ARG0 ];

    Logger->log({level => 'info', message => 'Got scope info data from DB'});

    #Logger->log(Dumper($result));
    foreach (@{$result->{result}}) {
	#Logger->log(Dumper($_));
	my %datum_info = (
	    frequency => $_->{frequency},
	    strength  => $_->{strength},
	    passid    => $_->{passid},
	    time      => $_->{time},
	    # not storing which radio in DB
	    #radio     => $self->{alias},
   	);
        $kernel->post( $self->{caller}, 'scope_datum' => \%datum_info );

    }


}

sub resync_scan_info {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    my $bank = $self->{config}{radio}{$self->{alias}}{scan_bank};
    Logger->log({level => 'info', 
               message => "radio told to sync scan $bank"});

    # might be a scan group in place so check
    Logger->log('banks:'.Dumper($self->{banks}));
    if (!$self->{banks}) {
	$kernel->yield( 'radio_cmd', 'BM' ); # the scan_bank may be part
	                                     # of a linked group
	$kernel->delay( 'resync_scan_info' => 3 );
	return;
    }

    # get the size of each bank
    foreach my $bank_bucket (sort keys %{$self->{banks}}) {
	
	if (!$self->{banks}{$bank_bucket}{max_slot}) {
 	    #$self->{banks}{$bank_bucket}{status} = 'pending';

	    Logger->log("next bank to get size of: |$bank_bucket|");
	    $kernel->yield( 'radio_cmd', sprintf('MW%s', $bank_bucket));
	    $kernel->delay( 'resync_scan_info' => 3 );
	    return;
        }
    }


    #Logger->log(Dumper($self->{banks}));
    foreach my $bank_bucket (sort keys %{$self->{banks}}) {
	my $status = $self->{banks}{$bank_bucket}{status};
	#Logger->log(Dumper(%bank));
	Logger->log("bank: $bank_bucket status: $status");
	if ($status eq 'pending') {
	    # kick off a bank query
	    $kernel->yield( 'radio_cmd', sprintf('MA%s', $bank_bucket));
	    $kernel->delay( 'resync_scan_info' => 3 );

	    last;
        } elsif ($status eq 'dumping') {
	    # get next block
	    $kernel->yield( 'radio_cmd', 'MA');
	    $kernel->delay( 'resync_scan_info' => 3 );

	    last;
	}
    }
    #foreach my $curbank (@$self->{banks}) {
	# if don't got all of this bank
	# then send command to radio to get next chunk


    #}

   #$kernel->call( $self->{alias}, 'radio_cmd', sprintf('SS%s', $bank) );
    #$self->{mode} = 'search';
    #$kernel->post( $self->{caller}, 'searching' => $self->{alias} );
}


sub hold {
    my $self = shift;
    
    my $freq = human_freq( $self->{scanned_freq} );

    Logger->log({level => 'info', message => "in radio hold.  freq: $freq"});

    my $freq_info_ref = $self->get_freq_info($freq);

    $poe_kernel->post( $self->{caller},
		       'tune' => $self->{alias},
		       'hold',
		       $freq_info_ref );

}

sub set_freq {
    my ($self, $freq) = @_;

    #my $freq;
    #if ($_[ARG0]) { $freq = $_[ARG0] } else { $freq = $_[HEAP]->{frequency } };


    Logger->log("someone wants freq $freq on $self->{alias}");
    $poe_kernel->call( $self->{alias}, 'radio_cmd', 'RF'. $freq );


}
sub raw_cmd {
    my ($self, $cmd) = @_;

    Logger->log("cmd: $cmd");
    $poe_kernel->call( $self->{alias}, 'radio_cmd', $cmd );


}

sub pass {
    my $self = shift;
    Logger->log("putting a pass on this channel");


    $poe_kernel->call( $self->{alias}, 'radio_cmd', 'MP1' );

    #$poe_kernel->yield( 'radio_cmd', 'MP1' );
}

sub aor_write_format {
    my ($matches, $bank, $label) = @_;

    my @matches = @$matches;

    my @cmds;
    my $i = 0;
    foreach (@matches) { 
	push @cmds, sprintf ( 'MX%1s%02d MP0 RF%10s AU1 TM%-12.12s', 
                             $bank, $i, aor_freq($_->{frequency}), $_->{designator} );
        $i++;
    }
    
    push @cmds, sprintf ( 'TB%1s%-8.8s' ,
                         $bank, $label );

    return @cmds;
}

sub aor_freq {
    my $freq = shift;
    
    my $aor_freq;
    if ($freq =~ /(\d+)\.(\d+)/) {
	$aor_freq = sprintf('%04s', $1) . substr($2 . '0' x (6 - length($2)), 0, 6);
        #Logger->log("freq: $freq aor_freq: $aor_freq  1: $1  2: $2");

    } else { 
	$aor_freq = sprintf('%04s', $freq) . '0' x 6 ;
	#Logger->log("no dec: $aor_freq");
    }
#    } else { $aor_freq = '0' x 10 }

    return $aor_freq;
}

sub human_freq {
    my $aor_freq = shift;
    
    my $human_freq;
    if ($aor_freq =~ /\d+/) {
	$human_freq = $aor_freq /= 1000000
    } else {
	$human_freq = 'INVALID'
    }

    return  $human_freq
}

sub set_speed ($$) {
   my $fh = shift || die;
    my $speed = shift;

    my $termios = POSIX::Termios->new() || die;
    $termios->getattr(fileno($fh)) || die "$!";

    eval("\$termios->setispeed(&POSIX::B$speed)") || die "$!";
    eval("\$termios->setospeed(&POSIX::B$speed)") || die "$!";


    $termios->setiflag( &POSIX::ICRNL );
    $termios->setiflag( &POSIX::IGNBRK );

    $termios->setlflag( &POSIX::ICANON );
    $termios->setlflag( &POSIX::IEXTEN );

    $termios->setoflag( &POSIX::OPOST );

    $termios->setattr(fileno($fh), &POSIX::TCSANOW);
}

sub log_sink {
    my ($self, $sink) = @_;

    if ($sink) {
	$self->{log_sink} = $sink;
	Logger->log("log_sink from $self->{alias} configured as |$sink|");
    } else {
	delete $self->{log_sink};
        Logger->log("log_sink removed");
    }

}

sub connected {
    
    return $_[OBJECT]->{connected};
}


sub scan_simulator {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    push my @freq_info, { car => int(rand(20))+1, frequency => 300.600,
                          comment => 'no comment' };

    $kernel->post( $self->{caller},
		   'tune' => $self->{alias},
		   'lock',
		   @freq_info );

    $kernel->delay_set ( 'scan_simulator', 2 );
    

}

1;

