package Plugins::MuslyMixer::Plugin;

#
# Musy 'Dont Stop The Music' mixer.
#
# (c) Craig Drummond, 2020
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
    require Plugins::MuslyMixer::Settings;
}

use Plugins::MuslyMixer::Settings;

*escape = main::ISWINDOWS ? \&URI::Escape::uri_escape : \&URI::Escape::uri_escape_utf8;

my $initialized = 0;
my $MuslyPort;
my @genreSets = ();
my $NUM_TRACKS = 20;
my $NUM_TRACKS_TO_USE = 5;
my $NUM_SEED_TRACKS = 5;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.muslymixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.muslymixer');

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres   => 1,
        port            => 11000,
    });

    if ( main::WEBUI ) {
        Plugins::MuslyMixer::Settings->new;
    }

    _initGenres();
    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MUSLYMIXER_MIX', sub {
            my ($client, $cb) = @_;

            my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $NUM_SEED_TRACKS);
            my $tracks = [];

            # don't seed from radio stations - only do if we're playing from some track based source
            # Get list of valid seeds...
            if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
                my @seedGenres = ();
                my @seedsToUse = ();
                foreach my $seedTrack (@$seedTracks) {
                    my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
                    if ($trackObj) {
                        my @genres = _getSeedGenres($trackObj->id);
                        main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack->{id} . " genres:" . Data::Dump::dump(@genres));
                        if (scalar @genres > 1) {
                            push @seedGenres, @genres;
                        }
                        push @seedsToUse, $trackObj;
                    }
                }

                if (scalar @seedsToUse > 0) {
                    my $mix = _getMix(\@seedsToUse);
                    main::idleStreams();

                    if ($mix && scalar @$mix) {
                        if (scalar @seedGenres > 1) {
                            # One or more seed tracks genres are listed in genres.json, so only allow similar genres
                            my %genrehash = map { $_ => 1 } @seedGenres;
                            foreach my $candidate (@$mix) {
                                my @cgenres = _getCandidateGenres($candidate);
                                my $count = scalar @cgenres;
                                my $found = 0;

                                for (my $i = 0; $i < $count && $found==0; $i++) {
                                    if (exists($genrehash{$cgenres[$i]})) {
                                        main::DEBUGLOG && $log->debug($candidate . " matched on genre " . $cgenres[$i]);
                                        push @$tracks, $candidate;
                                        $found=1;
                                    }
                                }

                                $found==0 && main::DEBUGLOG && $log->debug($candidate . " FAILED to match genre");

                                # Stop processing if we have enough acceptable tracks...
                                if ($found==1 && scalar(@$tracks)>=($NUM_TRACKS_TO_USE*2)) {
                                    main::DEBUGLOG && $log->debug("Have sufficient tracks");
                                    last;
                                }
                            }
                        } else {
                            # Seed track genres are not in genres.json - so can't filter!
                            push @$tracks, @$mix;
                        }
                    }
                }
            }

            $tracks = Slim::Plugin::DontStopTheMusic::Plugin->deDupe($tracks);
            # If we have more than 2*num tracks, then use 1st 2*num - and then shuffle those...
            if ( scalar @$tracks > ($NUM_TRACKS_TO_USE*2) ) {
                $tracks = [ splice(@$tracks, 0, $NUM_TRACKS_TO_USE*2) ];
            }
            if ( scalar @$tracks > $NUM_TRACKS_TO_USE ) {
                Slim::Player::Playlist::fischer_yates_shuffle($tracks);
                $tracks = [ splice(@$tracks, 0, $NUM_TRACKS_TO_USE) ];
            }

            $cb->($client, $tracks);
        });
    }
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'MuslyMIXER';
}

sub _getMix {
    my $seedTracks = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @mix = ();
    my $req;
    my $res;

    my %args = (
            # Set the size of the list
            'count'  => $NUM_TRACKS,
            'format' => 'text'
        );

    my $argString = join( '&', map { "$_=$args{$_}" } keys %args );

    # url encode the request, but not the argstring
    my $mixArgs = join('&', map {
        my $id = index($_->url, '#')>0 ? $_->url : $_->path;
        $id = main::ISWINDOWS ? $id : Slim::Utils::Unicode::utf8decode_locale($id);
        'track=' . escape($id);
    } @tracks);

    main::DEBUGLOG && $log->debug("Request http://localhost:$MuslyPort/api/similar?$mixArgs\&$argString");

    my $response = _syncHTTPRequest("/api/similar?$mixArgs\&$argString");

    if ($response->is_error) {
        $log->warn("Warning: Couldn't get mix: $mixArgs\&$argString");
        main::DEBUGLOG && $log->debug($response->as_string);
        return \@mix;
    }

    my @songs = split(/\n/, $response->content);
    my $count = scalar @songs;

    for (my $j = 0; $j < $count; $j++) {
        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
            $songs[$j] = Win32::GetANSIPathName($songs[$j]);
        }

        if ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j]) || index($songs[$j], 'file:///')==0) {
            push @mix, Slim::Utils::Misc::fileURLFromPath($songs[$j]);
        } else {
            $log->error('Musly attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
        }
    }

    return \@mix;
}

sub _syncHTTPRequest {
    my $url = shift;
    $MuslyPort = $prefs->get('port') unless $MuslyPort;
    my $http = LWP::UserAgent->new;
    $http->timeout($prefs->get('timeout') || 5);
    return $http->get("http://localhost:$MuslyPort$url");
}

sub _initGenres {
    my $filePath = Slim::Utils::Prefs::dir() . "/genres.json";
    if (! -e $filePath) {
        $filePath = dirname(__FILE__) . "/genres.json";
    }
    
    my $json = read_file($filePath);
    my $data = decode_json($json);
    @genreSets = ();
    if ($data) {
        my $dbh = Slim::Schema->dbh;
        my $sql = $dbh->prepare_cached( qq{SELECT genres.id FROM genres WHERE name = ? LIMIT 1} );
        foreach my $s (@$data) {
            my $set={};
            my $count = 0;
            foreach my $genre (@$s) {
                $sql->execute($genre);
                if ( my $result = $sql->fetchall_arrayref({}) ) {
                    my $val = $result->[0]->{'id'} if ref $result && scalar @$result;
                    if ($val) {
                        $set->{$val}=1;
                        $count++;
                    }
                }
            }

            if ($count>1) {
                push(@genreSets, $set);
            }
        }
    }
}

sub _getSeedGenres {
    my $track = shift;
    my @genres = ();
    if ($prefs->get('filter_genres')) {
        my @lmsgenres = ();
        # Get genres stored in LMS for this track
        my $dbh = Slim::Schema->dbh;
        my $sql = $dbh->prepare_cached( qq{SELECT genre FROM genre_track WHERE track = ?} );
        $sql->execute($track);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            if (ref $result && scalar @$result) {
                foreach my $r (@$result) {
                    push (@lmsgenres, $r->{'genre'})
                }
            }
        }

        foreach my $lmsgenre (@lmsgenres) {
            for my $href (@genreSets) {
                my %hash = %$href;
                if (exists($hash{$lmsgenre})) {
                    push (@genres, keys %hash); 
                }
            }
        }
    }

    return @genres;
}

sub _getCandidateGenres {
    my $url = shift;
    my @genres = ();
    my $dbh = Slim::Schema->dbh;
    my $sql = $dbh->prepare_cached( qq{SELECT id FROM tracks WHERE url = ? LIMIT 1} );
    $sql->execute($url);
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        if (ref $result && scalar @$result) {
            my $sql = $dbh->prepare_cached( qq{SELECT genre FROM genre_track WHERE track = ?} );
            $sql->execute($result->[0]->{'id'});
            if ( my $result = $sql->fetchall_arrayref({}) ) {
                if (ref $result && scalar @$result) {
                    foreach my $r (@$result) {
                        push (@genres, $r->{'genre'})
                    }
                }
            }
        }
    }
    main::DEBUGLOG && $log->debug("Candidate " . $url . " genres: " . Data::Dump::dump(@genres));
    return @genres;
}

1;

__END__
