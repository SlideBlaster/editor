#!/usr/bin/env perl
# LaTeXML WASM driver: read a full LaTeX document from the file named in ARGV[0],
# convert it to a LaTeXML HTML5 page in-process (tex -> xml -> html5, no fork),
# inline the referenced CSS as <style> blocks, and print the page to STDOUT.
#
# This is the in-WASM entry point behind the TypeScript LatexmlEngine. Emscripten
# has no fork/exec, so the whole latexml + latexmlpost pipeline runs in ONE
# process via the LaTeXML daemon API ($converter->convert), never a subprocess pair.
use strict;
use warnings;
use POSIX ();
use LaTeXML;
use LaTeXML::Common::Config;

my $texfile = $ARGV[0] or die "usage: latexml-driver.pl <texfile>\n";
# Slurp with $/ scoped to the do-block so it never leaks into LaTeXML's own reads.
my $tex = do {
  open(my $fh, '<:encoding(UTF-8)', $texfile) or die "cannot read $texfile: $!\n";
  local $/;
  <$fh>;
};

my $opts = LaTeXML::Common::Config->new(
  input_limit => 100,
  format      => 'html5',
  whatsin     => 'document',
  whatsout    => 'document',
  post        => 1,
  mathimages  => 0,
  verbosity   => 0,
);
$opts->check;
my $converter = LaTeXML->get_converter($opts);
$converter->prepare_session($opts);
my $response = $converter->convert("literal:$tex");
die "conversion failed: " . (($response && $response->{status}) || 'no response') . "\n"
  unless $response && $response->{result};

my $html = $response->{result};
$html = $html->toString(1) if ref $html;

# Locate LaTeXML's CSS resource dir (…/LaTeXML/resources/CSS) from the loaded module.
my $latexml_pm = $INC{'LaTeXML.pm'};
(my $cssdir = $latexml_pm) =~ s{\.pm$}{/resources/CSS};

# Inline each referenced stylesheet as a <style> block so the fragment is
# self-contained (the daemon references CSS by name; no files are written).
sub _inline_css {
  my ($href) = @_;
  (my $base = $href) =~ s{.*/}{};
  my $path = "$cssdir/$base";
  return "<!-- css:$base missing -->" unless -f $path;
  open(my $c, '<:encoding(UTF-8)', $path) or return "<!-- css:$base unreadable -->";
  local $/;
  my $css = <$c>;
  close $c;
  return "<style type=\"text/css\">\n$css</style>";
}
$html =~ s{<link\b[^>]*\brel="stylesheet"[^>]*\bhref="([^"]+)"[^>]*/?>}{_inline_css($1)}ge;

binmode(STDOUT, ':encoding(UTF-8)');
print $html;
# Force a clean, immediate exit: emscripten's NO_EXIT_RUNTIME perl otherwise
# hangs in global destruction instead of terminating. Flush first.
STDOUT->flush;
POSIX::_exit(0);
