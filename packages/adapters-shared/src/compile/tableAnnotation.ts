/**
 * Table source-annotation: the LaTeXML preload binding that stamps every compiled
 * `tabular` cell with its physical grid position (`data-sbx` / `data-sby`), plus the
 * MEMFS injection that activates it at runtime WITHOUT rebuilding the wasm.
 *
 * latexml compiles a `tabular` to HTML one-way, so the canvas shallow-edit affordance
 * cannot read a clicked cell's source back from the HTML. The binding closes that gap:
 * it labels each rendered `<td>` with the grid coordinate latexml already knows while
 * parsing, and the editor resolves that coordinate to a source cell via
 * `resolveTabularCell` (see editor content/tabular.ts). Identity therefore originates
 * in the source (latexml's own parse), never in the HTML structure.
 *
 * Why a runtime injection rather than a baked binding: the LaTeXML Perl tree ships in a
 * prebuilt `.data` MEMFS image. We avoid rebuilding it by writing the binding file into
 * that (writable) MEMFS at boot and adding a `preload` to the in-image driver. LaTeXML's
 * html5 output already copies foreign-namespace attributes to `data-*` (the pre-registered
 * `data:` prefix -> `data-<name>`), so no XSLT change is needed either. It is best-effort:
 * if the MEMFS layout ever differs the writes are swallowed and tables still compile,
 * just without coordinates (the canvas then offers deep-edit only).
 */

/** Path of the injected binding inside the LaTeXML MEMFS. */
export const BINDING_PATH = '/sb/sbannot.ltxml'
/** Path of the in-image conversion driver whose options we extend. */
export const DRIVER_PATH = '/sb/driver.pl'

/**
 * The preload binding (a LaTeXML `.ltxml` Perl fragment). latexml filters its own cell
 * x/y before our `afterOpen` hook runs, so we reconstruct the physical grid from
 * colspan/rowspan occupancy — which is exactly what a `\multirow` overhang shifts on the
 * render side, keeping our x/y in lockstep with the source grid `parseTabular` computes.
 */
export const ANNOTATION_BINDING = `# sbannot.ltxml - SlideBlaster table cell annotation (injected at runtime).
# Stamps every compiled tabular cell with its physical grid position as
# data-sbx / data-sby so the canvas can resolve a rendered <td> to its source cell,
# even across \\multicolumn / \\multirow. Consumed by editor content/tabular.ts.
use strict;
use warnings;
use LaTeXML::Package;

# The 'data' namespace is pre-registered by TeX.pool: data:<name> -> data-<name>.
our @SB_STACK;    # saved states, for nested tabulars
our $SB;          # current: { y => int, x => int, occ => { "x,y" => 1 } }

Tag('ltx:tabular', afterOpen => sub {
  push(@SB_STACK, $SB) if $SB;
  $SB = { y => -1, x => 0, occ => {} };
  return;
});
Tag('ltx:tabular', afterClose => sub {
  $SB = pop(@SB_STACK);
  return;
});
Tag('ltx:tr', afterOpen => sub {
  return unless $SB;
  $SB->{y} += 1;
  $SB->{x} = 0;
  return;
});
Tag('ltx:td', afterOpen => sub {
  my ($document, $node) = @_;
  return unless $SB;
  my $y = $SB->{y};
  while ($SB->{occ}{ $SB->{x} . ',' . $y }) { $SB->{x} += 1; }
  my $x       = $SB->{x};
  my $colspan = $node->getAttribute('colspan') || 1;
  my $rowspan = $node->getAttribute('rowspan') || 1;
  for my $dx (0 .. $colspan - 1) {
    for my $dy (1 .. $rowspan - 1) {
      $SB->{occ}{ ($x + $dx) . ',' . ($y + $dy) } = 1;
    }
  }
  $document->setAttribute($node, 'data:sbx', $x);
  $document->setAttribute($node, 'data:sby', $y);
  $SB->{x} += $colspan;
  return;
});

1;
`

/**
 * Add the `sbannot` preload to the driver's `LaTeXML::Common::Config->new(...)`, unless
 * it is already there. Idempotent and format-stable: it anchors on the constructor call
 * and inserts two options right after the opening paren. Returns the driver unchanged if
 * the anchor is absent (older/rebuilt driver that already carries the preload, or a
 * layout we do not recognize).
 */
export function patchDriver(driver: string): string {
  if (driver.includes('sbannot')) return driver
  const anchor = 'LaTeXML::Common::Config->new('
  const i = driver.indexOf(anchor)
  if (i === -1) return driver
  const at = i + anchor.length
  return `${driver.slice(0, at)}\n  preload => ['sbannot.ltxml'],\n  paths => ['/sb'],${driver.slice(at)}`
}

/** The minimal MEMFS surface the injection touches (a subset of emscripten's Module.FS). */
export interface AnnotationFs {
  writeFile(path: string, data: string): void
  readFile(path: string, opts: { encoding: 'utf8' }): string
}

/**
 * Write the binding into the MEMFS and extend the driver to preload it. Call once per
 * booted interpreter, before the first conversion. Best-effort: any FS error is swallowed
 * so a conversion never fails just because coordinates could not be installed.
 */
export function installTableAnnotation(
  fs: AnnotationFs,
  binding: string = ANNOTATION_BINDING,
): void {
  try {
    fs.writeFile(BINDING_PATH, binding)
    const driver = fs.readFile(DRIVER_PATH, { encoding: 'utf8' })
    const patched = patchDriver(driver)
    if (patched !== driver) fs.writeFile(DRIVER_PATH, patched)
  } catch {
    // Best-effort — see module doc.
  }
}
