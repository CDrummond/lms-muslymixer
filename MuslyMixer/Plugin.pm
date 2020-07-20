package Plugins::MuslyMixer::Plugin;

#
# Musly 'Dont Stop The Music' mixer.
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
my $NUM_TRACKS = 15;
my $NUM_TRACKS_TO_USE = 5;
my $NUM_SEED_TRACKS = 5;
my $IGNORE_LAST_TRACKS = 50;

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
        filter_genres => 1,
        port          => 11000,
        min_duration  => 0,
        max_duration  => 0
    });

    if ( main::WEBUI ) {
        Plugins::MuslyMixer::Settings->new;
    }

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
            my $ignoreTracks = _getPlaylist($client, $IGNORE_LAST_TRACKS);
            my $tracks = [];

            # don't seed from radio stations - only do if we're playing from some track based source
            # Get list of valid seeds...
            if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
                my @seedIds = ();
                my @seedsToUse = ();
                foreach my $seedTrack (@$seedTracks) {
                    my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
                    if ($trackObj) {
                        main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack->{id});
                        push @seedsToUse, $trackObj;
                        push @seedIds, $seedTrack->{id};
                    }
                }

                if (scalar @seedsToUse > 0) {
                    my @tracksToIgnore = ();
                    if ($ignoreTracks && ref $ignoreTracks && scalar @$ignoreTracks) {
                        my %hash = map { $_ => 1 } @seedIds;
                        foreach my $ignoreTrack (@$ignoreTracks) {
                            if (!exists($hash{$ignoreTrack})) {
                                my ($trackObj) = Slim::Schema->find('Track', $ignoreTrack);
                                if ($trackObj) {
                                    push @tracksToIgnore, $trackObj;
                                }
                            }
                        }
                        main::DEBUGLOG && $log->debug("Num tracks to ignore: " . scalar(@tracksToIgnore));
                    }

                    my $mix = _getMix(\@seedsToUse, \@tracksToIgnore);
                    main::idleStreams();
                    if ($mix && scalar @$mix) {
                        push @$tracks, @$mix;
                    }
                }
            }

            # Remove duplicates...
            my $deDupTracks = Slim::Plugin::DontStopTheMusic::Plugin->deDupe($tracks);
            if ( scalar @$deDupTracks < $NUM_TRACKS_TO_USE ) {
                main::DEBUGLOG && $log->debug("Too few tracks after de-dupe, use orig");
                $deDupTracks = $tracks;
            }

            # Shuffle tracks...
            Slim::Player::Playlist::fischer_yates_shuffle($deDupTracks);

            # If we have more than num tracks, then use 1st num...
            if ( scalar @$deDupTracks > $NUM_TRACKS_TO_USE ) {
                $deDupTracks = [ splice(@$deDupTracks, 0, $NUM_TRACKS_TO_USE) ];
            }
            $cb->($client, $deDupTracks);
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

sub _getPlaylist {
    my ($client, $count) = @_;
    return unless $client;

    $client = $client->master;
    my ($trackId, $artist, $title, $duration, $mbid, $artist_mbid, $tracks);

    foreach (@{ Slim::Player::Playlist::playList($client) }) {
        ($artist, $title, $duration, $trackId, $mbid, $artist_mbid) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);
        next unless defined $artist && defined $title;
        push @$tracks, $trackId;
    }

    return $tracks;
    if ($tracks && ref $tracks) {
        my $num = scalar $tracks;
        if ($num > 0) {
            if ($num > $count) {
                $tracks = [ splice(@$tracks, $num - $count, $count) ];
            }
            return $tracks;
        }
    }
}

sub _getMix {
    my $seedTracks = shift;
    my $ignoreTracks = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @ignore = ref $ignoreTracks ? @$ignoreTracks : ($ignoreTracks);
    my @mix = ();
    my $req;
    my $res;

    my %args = (
            'count'       => $NUM_TRACKS,
            'format'      => 'text',
            'filtergenre' => $prefs->get('filter_genres'),
            'min'         => $prefs->get('min_duration'),
            'max'         => $prefs->get('max_duration')
        );

    my $argString = join( '&', map { "$_=$args{$_}" } keys %args );

    # url encode the request, but not the argstring
    my $mixArgs = join('&', map {
        my $id = index($_->url, '#')>0 ? $_->url : $_->path;
        $id = main::ISWINDOWS ? $id : Slim::Utils::Unicode::utf8decode_locale($id);
        'track=' . escape($id);
    } @tracks);

    my $reqUrl = "/api/similar?$mixArgs\&$argString";

    if (scalar @ignore > 0) {
        my $ignoreArgs = join('&', map {
            my $id = index($_->url, '#')>0 ? $_->url : $_->path;
            $id = main::ISWINDOWS ? $id : Slim::Utils::Unicode::utf8decode_locale($id);
            'ignore=' . escape($id);
        } @ignore);
        $reqUrl = "$reqUrl\&$ignoreArgs";
    }

    my $response = _syncHTTPRequest($reqUrl);

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
    main::DEBUGLOG && $log->debug("Request http://localhost:$MuslyPort$url");
    return $http->get("http://localhost:$MuslyPort$url");
}

1;

__END__
