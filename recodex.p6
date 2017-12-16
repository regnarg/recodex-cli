#!/usr/bin/perl6

use Inline::Perl5;
use WWW::Mechanize:from<Perl5>;
use Term::ReadPassword:from<Perl5>;
use JSON::Fast;

my $token-file = (%*ENV<XDG_CACHE_DIR> // "%*ENV<HOME>/.cache").IO.child("recodex-token");
my $token;
my $root = "https://recodex.mff.cuni.cz/api/v1";
multi to-str(Str $x) { $x }
multi to-str(Blob $x) { $x.decode("utf-8") }

sub cas-login($username, $password) {
    my $mech = WWW::Mechanize.new(:autocheck);
    #$mech.add_handler("request_send",  ->$r, *@ { note "REQ "~to-str($r.dump); Any; });
    #$mech.add_handler("response_done", ->$r, *@ { note "RESP "~to-str($r.dump); Any; });
    $mech.get: "https://idp.cuni.cz/cas/login?service=https%3A%2F%2Frecodex.mff.cuni.cz%2Fen&renew=true";
    $mech.submit_form(:form_id<fm1>, :fields{ :$username, :$password });

    my $ticket = ~($mech.content ~~ /'"ticket":"' (<-["]>+) '"'/ or fail "bad login")[0];

    $mech.post: "$root/login/cas-uk/oauth", :Content-Type<application/x-www-form-urlencoded>,
                Content => { :$ticket, :clientUrl<https://recodex.mff.cuni.cz/en> };
    my $token = $mech.content.&to-str.&from-json<payload><accessToken>;
    $token;
}

sub login($username, $password) {
    my $resp = post "login", Content => { :$username, :$password };
    $resp<accessToken>;
}

class FileUpload {
    has $.local;
    has $.name = $!local.IO.basename;
    has $.type = "text/plain;charset=UTF-8";
}

# ReCodEx parses requests using PHP's braindead default array parametr handling, e.g.:
# environmentConfigs[0][runtimeEnvironmentId]=python3&environmentConfigs[0][variablesTable][0][name]=source-file&...
# It does not accept structured JSON input.
sub flatten-form-data(%data) {
    multi flatten($_, $prefix) {
        when Positional|Associative {
            $_.kv.map: -> $idx, $elem { | flatten($elem, $prefix~"[$idx]")  }
        }
        when Str|Numeric {
            $prefix => $_
        }
        when FileUpload {
            $prefix => [.local, .name, "Content_Type", .type]
        }
    }
    my @query = %data.kv.map: -> $name, $val { | flatten($val, $name) };
}

sub api-request($meth, $path, *%kw) {
    my %lwp-kw;
    my %form-data = %kw<form-data>:delete // ();
    for %kw.kv -> $_, $val {
        when /^"hdr-"(.*)/ { %lwp-kw{$0.subst("-", "_",:g)} = $val; }
        when /[Content]/ { %lwp-kw{$_} = $val; }
        default { %form-data{$_} = $val; }
    }
    if (%form-data) { %lwp-kw<Content> = flatten-form-data(%form-data); }
    note "$meth.uc() $root/$path";
    my $lwp-args = \("$root/$path", Authorization => "Bearer $token", |%lwp-kw);
    note $lwp-args.perl;
    my $resp = LWP::UserAgent.new."$meth"(|$lwp-args);
    note "RESPONSE " ~ $resp.code ~ " " ~ $resp.content.&to-str;
    if ($resp.code != 200) { die "HTTP error $resp.code()" ~ $resp.content(); }

    my $data = $resp.content.&to-str.&from-json;
    if ($data<code> != 200) { fail "API error: $resp.content()"; }

    $data<payload>;
}

sub get(|args)    { api-request("get",    |args); }
sub post(|args)   { api-request("post",   |args); }
sub delete(|args) { api-request("delete", |args); }
sub put(|args)    { api-request("put",    |args); }

sub save-token($token) {
    $token-file.spurt($token);
}

sub load-token() {
    ($token-file.slurp // return).trim;
}
$token = load-token;

role ApiPrefix {
    method request($meth, $path, |rest) { api-request $meth, "$.prefix/$path", |rest; }
    method get(|args)    { $.request("get",    |args); }
    method post(|args)   { $.request("post",   |args); }
    method delete(|args) { $.request("delete", |args); }
    method put(|args)    { $.request("put",    |args); }
}

class Exercise does ApiPrefix {
    has $.id;
    has $.prefix = "exercises/$!id";
    constant %ENVS = {
        :c<     c-gcc-linux         *.{c,h}             >,
        :cpp<   cxx-gcc-linux       *.{cpp,cxx,h,hpp}   >,
        :pas<   freepascal-linux    *.{pas,lpr}         >,
    };
    method setup-envs {
        
    }
    #submethod BUILD { $!prefix = "exercises/$!id"; }
    method list-files { $.get("supplementary-files"); }
    method delete-file($name) {
        for $.list-files.grep({ $_<name> eq $name }) {
            $.delete("supplementary-files/$_<id>");
        }
    }
    method upload-file($local, :$name=$local.IO.basename) {
        $.delete-file($name);
        my $upload-resp = post("uploaded-files", :hdr-content-type<form-data>,
                            Content => { $name => [~$local, ~$name, "Content_Type", "text/plain;charset=UTF-8"] });
        my $add-resp = $.post("supplementary-files", Content => { "files[0]" => $upload-resp<id> });
        $add-resp<id>;
    }
}

multi MAIN("repl") {
    use Debug::REPLHere;
    repl-here;
}

multi MAIN("login", Str $username? is copy, :$cas=False) {
    without $username {
        $*ERR.print(($cas ?? "CAS " !! "") ~ "Username: ");
        $username = $*IN.get;
    }
    $*ERR.print(($cas ?? "CAS " !! "") ~ "Password: ");
    my $password = read_password();

    my $token = ($cas ?? &cas-login !! &login)($username, $password);
    unless $token { die "Got empty token"; }
    save-token $token;
}

multi get-exercise-id(Any:U) { %*ENV<RECODEX_TASK> }
multi get-exercise-id(Str:D $task where /[ <.xdigit>+ ] **3..* % '-'/) {
    $task
}
sub get-exercise($task) { Exercise.new(id => get-exercise-id($task)) }
# TODO: lookup by some nicer identifier (store somewhere in metadata)

multi MAIN("upload-file", *@files, :$task) {
    my $ex = get-exercise($task);
    note $ex.prefix;
    $ex.upload-file($_) for @files;
}

multi MAIN("upload-task", $task-id) {


}