---
title: "P4Check: Branching Time Model Checking for P4 Programmable Data Planes"
authors: Tommaso Pacciani, L. Thomas van Binsbergen, Chrysa Papagianni
bibliography: bib.bib
page-numbers: true
theme: fns
citation-style: numeric
preamble: |
  \usepackage{amsmath,amssymb}
---

## New Slide

## Software Defined Networking - P4

<div kind="text" style="position: absolute; left: 4.641154199217454vw; top: 18.29461528055215vh; width: 76.73582266804657vw; height: 20.315192227090854vh; z-index: 10; font-size: 4vw; color: #333333"><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* A DSL for programming packet processors (Switches, SmartNICs, ...)</span><br><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* Generalizes OpenFlow, protocol-independent</span><br><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">Impact:</span><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">Industry:</span><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* Novel internet architectures \citefootnote{10.1145/3485983.3494839, style="position: absolute; left: 4.888738478789349vw; top: 87.77559064431595vh; width: 78.42880179409202vw; height: 8vh; z-index: 3"}\citefootnote{11181709, style="position: absolute; left: 4.999999999999998vw; top: 91.16477215888082vh; width: 80.20898613346249vw; height: 8vh; z-index: 5"}</span><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* As a model \citefootnote{10.1145/3544216.3544220, style="position: absolute; left: 5vw; top: 96vh; width: 58.461484921336904vw; height: 8vh; z-index: 7"}</span><br><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">Academia:</span><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* in-band telemetry</span><br><span style="color:rgb(51, 51, 51);font-size:3.9999997534644733vh">* Network applications </span></div>

## match+action paradigm

<div kind="raw-html" style="position: absolute; left: 3vw; top: 22vh; width: 94vw; height: 70vh; z-index: 1">
  <svg viewBox="0 0 920 280" width="100%" xmlns="http://www.w3.org/2000/svg" font-family="'Segoe UI', Arial, sans-serif">
    <defs>
      <marker id="arrBlue" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
        <path d="M0,0 L8,3 L0,6 Z" fill="#3b6cb5"/>
      </marker>
      <marker id="arrRed" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
        <path d="M0,0 L8,3 L0,6 Z" fill="#c0392b"/>
      </marker>
      <marker id="arrGraph" markerWidth="5" markerHeight="5" refX="4" refY="2.5" orient="auto">
        <path d="M0,0 L5,2.5 L0,5 Z" fill="#c0392b"/>
      </marker>
    </defs>

    <!-- ===== INPUT RED ARROW ===== -->
    <line x1="2" y1="140" x2="42" y2="140" stroke="#c0392b" stroke-width="3" marker-end="url(#arrRed)"/>

    <!-- ===== PARSER ===== -->
    <rect x="52" y="40" width="90" height="200" rx="6" fill="#d5e8d4" stroke="#82b366" stroke-width="2"/>
    <!-- Parse graph nodes -->
    <circle cx="78" cy="70" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="118" cy="65" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="75" cy="115" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="120" cy="110" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="80" cy="160" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="115" cy="165" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="78" cy="205" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <circle cx="118" cy="210" r="10" fill="none" stroke="#333" stroke-width="1.8"/>
    <!-- Self-loop on node 1 (top-left) -->
    <path d="M72,61 C58,42 90,42 84,61" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <!-- Self-loop on node 4 (mid-right) -->
    <path d="M126,101 C140,82 140,118 126,119" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <!-- Graph edges -->
    <path d="M88,70 Q100,65 108,65" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M118,75 Q116,90 112,100" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M78,80 Q76,95 76,105" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M85,115 Q98,112 110,110" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M75,125 Q78,140 79,150" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M90,160 Q100,162 105,165" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M115,175 Q112,188 110,200" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M80,170 Q79,185 78,195" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <path d="M88,205 Q100,207 108,210" stroke="#c0392b" stroke-width="1.3" fill="none" marker-end="url(#arrGraph)"/>
    <!-- Parser label -->
    <text x="97" y="260" text-anchor="middle" font-size="13" font-weight="600" fill="#333">Parser</text>

    <!-- ===== ARROW: Parser -> Stage 1 ===== -->
    <line x1="148" y1="140" x2="188" y2="140" stroke="#3b6cb5" stroke-width="3" marker-end="url(#arrBlue)"/>

    <!-- ===== STAGE 1 ===== -->
    <rect x="198" y="40" width="130" height="200" rx="6" fill="#dae8fc" stroke="#6c8ebf" stroke-width="2"/>
    <text x="263" y="30" text-anchor="middle" font-size="12" font-weight="600" fill="#1a3a5c">Match+Action Stage</text>
    <!-- Row 1 -->
    <rect x="208" y="52" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="239" y="69" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="278,52 310,65 278,78" fill="#e8944a"/>
    <text x="293" y="69" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <!-- Row 2 -->
    <rect x="208" y="86" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="239" y="103" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="278,86 310,99 278,112" fill="#e8944a"/>
    <text x="293" y="103" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <!-- Row 3 -->
    <rect x="208" y="120" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="239" y="137" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="278,120 310,133 278,146" fill="#e8944a"/>
    <text x="293" y="137" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <!-- Row 4 -->
    <rect x="208" y="154" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="239" y="171" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="278,154 310,167 278,180" fill="#e8944a"/>
    <text x="293" y="171" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <!-- Row 5 -->
    <rect x="208" y="188" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="239" y="205" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="278,188 310,201 278,214" fill="#e8944a"/>
    <text x="293" y="205" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>

    <!-- ===== ARROW: Stage 1 -> Stage 2 ===== -->
    <line x1="333" y1="140" x2="373" y2="140" stroke="#3b6cb5" stroke-width="3" marker-end="url(#arrBlue)"/>

    <!-- ===== STAGE 2 ===== -->
    <rect x="383" y="40" width="130" height="200" rx="6" fill="#dae8fc" stroke="#6c8ebf" stroke-width="2"/>
    <rect x="393" y="52" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="424" y="69" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="463,52 495,65 463,78" fill="#e8944a"/>
    <text x="478" y="69" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="393" y="86" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="424" y="103" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="463,86 495,99 463,112" fill="#e8944a"/>
    <text x="478" y="103" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="393" y="120" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="424" y="137" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="463,120 495,133 463,146" fill="#e8944a"/>
    <text x="478" y="137" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="393" y="154" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="424" y="171" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="463,154 495,167 463,180" fill="#e8944a"/>
    <text x="478" y="171" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="393" y="188" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="424" y="205" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="463,188 495,201 463,214" fill="#e8944a"/>
    <text x="478" y="205" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>

    <!-- ===== ARROW: Stage 2 -> Stage 3 ===== -->
    <line x1="518" y1="140" x2="558" y2="140" stroke="#3b6cb5" stroke-width="3" marker-end="url(#arrBlue)"/>

    <!-- ===== STAGE 3 ===== -->
    <rect x="568" y="40" width="130" height="200" rx="6" fill="#dae8fc" stroke="#6c8ebf" stroke-width="2"/>
    <rect x="578" y="52" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="609" y="69" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="648,52 680,65 648,78" fill="#e8944a"/>
    <text x="663" y="69" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="578" y="86" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="609" y="103" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="648,86 680,99 648,112" fill="#e8944a"/>
    <text x="663" y="103" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="578" y="120" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="609" y="137" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="648,120 680,133 648,146" fill="#e8944a"/>
    <text x="663" y="137" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="578" y="154" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="609" y="171" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="648,154 680,167 648,180" fill="#e8944a"/>
    <text x="663" y="171" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="578" y="188" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="609" y="205" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="648,188 680,201 648,214" fill="#e8944a"/>
    <text x="663" y="205" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>

    <!-- ===== ARROW: Stage 3 -> Stage 4 ===== -->
    <line x1="703" y1="140" x2="743" y2="140" stroke="#3b6cb5" stroke-width="3" marker-end="url(#arrBlue)"/>

    <!-- ===== STAGE 4 ===== -->
    <rect x="753" y="40" width="130" height="200" rx="6" fill="#dae8fc" stroke="#6c8ebf" stroke-width="2"/>
    <rect x="763" y="52" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="794" y="69" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="833,52 865,65 833,78" fill="#e8944a"/>
    <text x="848" y="69" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="763" y="86" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="794" y="103" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="833,86 865,99 833,112" fill="#e8944a"/>
    <text x="848" y="103" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="763" y="120" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="794" y="137" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="833,120 865,133 833,146" fill="#e8944a"/>
    <text x="848" y="137" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="763" y="154" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="794" y="171" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="833,154 865,167 833,180" fill="#e8944a"/>
    <text x="848" y="171" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>
    <rect x="763" y="188" width="62" height="26" rx="3" fill="#3b6cb5"/>
    <text x="794" y="205" text-anchor="middle" font-size="9" font-weight="600" fill="#fff">Memory</text>
    <polygon points="833,188 865,201 833,214" fill="#e8944a"/>
    <text x="848" y="205" text-anchor="middle" font-size="8" font-weight="700" fill="#fff">ALU</text>

    <!-- ===== OUTPUT RED ARROW ===== -->
    <line x1="888" y1="140" x2="915" y2="140" stroke="#c0392b" stroke-width="3" marker-end="url(#arrRed)"/>
  </svg>
</div>

## Example: P4 Program

<div kind="raw-html" style="position: absolute; left: 2vw; top: 15vh; width: 96vw; height: 83vh; z-index: 1">
  <style>
    .p4-cols { display: flex; gap: 1.5vw; height: 100%; }
    .p4-cols .p4-col { flex: 1; overflow: auto; }
    .p4-cols pre {
      margin: 0;
      padding: 1vh 0.8vw;
      font-size: 1.4vh;
      line-height: 1.5;
      background: #f6f8fa;
      border-radius: 6px;
      border: 1px solid #d0d7de;
      overflow-x: auto;
    }
    .p4-cols .p4-label {
      text-align: center;
      font-weight: 600;
      font-size: 2vh;
      margin-bottom: 0.5vh;
      color: #555;
    }
  </style>
  <div class="p4-cols">
    <div class="p4-col">
      <div class="p4-label">Headers &amp; Parser</div>
      <pre><code>#include &lt;core.p4&gt;
#include &lt;v1model.p4&gt;

const bit&lt;16&gt; TYPE_IPV4 = 0x800;

typedef bit&lt;9&gt;  egressSpec_t;
typedef bit&lt;48&gt; macAddr_t;
typedef bit&lt;32&gt; ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit&lt;16&gt;   etherType;
}

header ipv4_t {
    bit&lt;4&gt;    version;
    ...
    ip4Addr_t dstAddr;
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
}

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t smeta) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}</code></pre>
    </div>
    <div class="p4-col">
      <div class="p4-label">Control Block</div>
      <pre><code>control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t smeta) {
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr,
                        egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}</code></pre>
    </div>
  </div>
</div>

## Existing tools

<div kind="text" style="position: absolute; left: 5.996826559483591vw; top: 30.989466593267878vh; width: 65.69604573304456vw; height: 2vh; z-index: 10; font-size: 5.5vw; color: #333333; text-align: left"><span style="color:rgb(51, 51, 51);font-size:3.4999997842814143vh">* Several tools exist for reasoning about P4:  </span><br><span style="color:rgb(51, 51, 51);font-size:3.4999997842814143vh"> * ASSERT-P4\cite{10.1145/3185467.3185499}, p4v\cite{10.1145/3230543.3230582}, Vera\cite{10.1145/3230543.3230548}, bf4\cite{10.1145/3387514.3405888}</span><br><span style="color:rgb(51, 51, 51);font-size:3.4999997842814143vh"> * p4tv</span><br><span style="color:rgb(51, 51, 51);font-size:2.9999998150983553vh"> * petr4, p4testgen, P4SpecTec </span><span style="color:rgb(51, 51, 51);font-size:3.000009432331846vh">\citefootnote{10.1145/3656440, style="position: absolute; left: 4.6631477919280995vw; top: 83.74725975844005vh; width: 68.52351546101329vw; height: 12.808616745365061vh; z-index: 3"}</span><br><br><span style="color:rgb(51, 51, 51);font-size:2.9999998150983553vh">* Aim:  Support both single and multi packet properties, support the latest variant of P4 </span><br><br></div>

## 

\center{Implementation, style="font-size:12vh"}

## Grisette by example

<div kind="raw-html" style="position: absolute; left: 2vw; top: 16vh; width: 96vw; height: 82vh; z-index: 1">
  <style>
    .two-col { display: flex; gap: 1.5vw; height: 100%; }
    .two-col .col { flex: 1; overflow: auto; }
    .two-col pre {
      margin: 0;
      padding: 1.2vh 1vw;
      font-size: 1.35vh;
      line-height: 1.55;
      background: #f6f8fa;
      border-radius: 6px;
      border: 1px solid #d0d7de;
      overflow-x: auto;
    }
    .two-col .col-label {
      text-align: center;
      font-weight: 600;
      font-size: 2.2vh;
      margin-bottom: 0.8vh;
      color: #333;
    }
  </style>
  <div class="two-col">
    <div class="col">
      <div class="col-label">Concrete</div>
      <pre><code class="language-haskell">data CExpr
  = CLit Int
  | CVar String
  | CBool Bool
  | CBinOp BinOp CExpr CExpr
  deriving (Show, Eq)

data CStmt
  = CAssign String CExpr
  | CIf CExpr CStmt CStmt
  | CSeq CStmt CStmt
  | CSkip
  deriving (Show, Eq)

data CVal = CInt Int | CBoolVal Bool
  deriving (Show, Eq)

type CEnv = [(String, CVal)]

evalCExpr :: CExpr -> StateT CEnv Identity CVal
evalCExpr (CBinOp op e1 e2) = do
  v1 <- evalCExpr e1
  v2 <- evalCExpr e2
  pure $ case (op, v1, v2) of
    (Add, CInt a, CInt b) -> CInt (a + b)
    (Lt,  CInt a, CInt b) -> CBoolVal (a < b)
    (Or,  CBoolVal a, CBoolVal b) -> CBoolVal (a || b)

evalCStmt :: CStmt -> StateT CEnv Identity ()
evalCStmt CSkip = pure ()
evalCStmt (CAssign x e) = do
  v <- evalCExpr e
  modify (updateCEnv x v)
evalCStmt (CIf cond thenS elseS) = do
  v <- evalCExpr cond
  case v of
    CBoolVal c -> if c then evalCStmt thenS
                       else evalCStmt elseS
    _ -> error "Type error: expected bool"
evalCStmt (CSeq s1 s2) =
  evalCStmt s1 >> evalCStmt s2

runConcrete :: CStmt -> CEnv -> CEnv
runConcrete stmt env =
  runIdentity $ execStateT (evalCStmt stmt) env</code></pre>
    </div>
    <div class="col">
      <div class="col-label">Symbolic (Grisette)</div>
      <pre><code class="language-haskell">data SExpr
  = SLit SymInteger
  | SVar String
  | SBool SymBool
  | SBinOp BinOp SExpr SExpr
  deriving (Show, Eq, Generic)

data SStmt
  = ...
  deriving (Show, Eq, Generic)
  deriving (Mergeable) via (Default SStmt)

data SVal = SInt SymInteger | SBoolVal SymBool
  deriving (Show, Eq, Generic)

type SEnv = [(String, SVal)]

evalSExpr :: SExpr -> StateT SEnv Union SVal
evalSExpr (SBinOp op e1 e2) = do
  v1 <- evalSExpr e1
  v2 <- evalSExpr e2
  mrgReturn $ case (op, v1, v2) of
    (Add, SInt a, SInt b) -> SInt (a + b)
    (Lt,  SInt a, SInt b) -> SBoolVal (a .< b)
    (Or,  SBoolVal a, SBoolVal b) -> SBoolVal (a .|| b)

evalSStmt :: SStmt -> StateT SEnv Union ()
evalSStmt SSkip = mrgReturn ()
evalSStmt (SAssign x e) = do
  v <- evalSExpr e
  mrgModify (updateEnv x v)
evalSStmt (SIf cond thenS elseS) = do
  v <- evalSExpr cond
  case v of
    SBoolVal c -> mrgIf c (evalSStmt thenS)
                          (evalSStmt elseS)
    _ -> error "Type error: expected bool"
evalSStmt (SSeq s1 s2) =
  evalSStmt s1 >> evalSStmt s2

runSymbolic :: SStmt -> SEnv -> Union SEnv
runSymbolic stmt env =
  execStateT (evalSStmt stmt) env</code></pre>
    </div>
  </div>
</div>

## Specification language

<div kind="text" style="position: absolute; left: 6.0509234978689435vw; top: 32.30813603777523vh; width: 40vw; height: 10vh; z-index: 10; font-size: 3vw; color: #333333"><span style="color:rgb(51, 51, 51);font-size:2.9999926630602336vh">* Instrument the program with variables to capture values at location</span><br><br></div>

<div kind="raw-html" style="position: absolute; left: 5.6vw; top: 50vh; width: 40vw; height: 30vh; z-index: 10" class="fragment appear">
  <pre style="font-size: 1.7vh; line-height: 1.7; background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5vh 1.2vw; color: #333; white-space: pre-wrap; font-family: 'Fira Code', 'Consolas', monospace;"><b>if</b> hdr.ipv4.isValid() <span style="color:#888">@MyIngress.begin</span>
<b>then</b>
  <b>if</b> !(standard_metadata.egress_spec <span style="color:#888">@MyIngress.end</span> == 9w511)
  <b>then</b>
    hdr.ipv4.ttl <span style="color:#888">@MyIngress.end</span> != 8w0
    <b>&amp;&amp;</b> hdr.ipv4.ttl <span style="color:#888">@MyEgress.end</span>
        == (hdr.ipv4.ttl <span style="color:#888">@MyIngress.begin</span> - 8w1)</pre>
</div>

\latex{\begin{align*}
\mathit{location} ::=~&~ name(x) && (\text{control or action})\\
    |~&~ start ~|~ end  \\[6pt]

\end{align*}, style="position: absolute; left: 39.98976903195986vw; top: 18.263377989686784vh; width: 53.156621862942885vw; height: 23.03452732018249vh; z-index: 1; font-size: 3vw"}

\latex{\begin{align*}

\mathit{spec} ::=~& \mathbf{if}\ \mathit{spec}\ \mathbf{then}\ \mathit{spec}\ \mathbf{else}\ \mathit{spec}? && {\text{(intra packet)}} \\ 
                 |~& \mathit{expr} @ \mathit{location}\\
                 |~& \mathit{const} \\
                 |~& \mathit{spec} \oplus \mathit{spec} && {\text{P4 operator}}
                 \\
                 \\
                 \hspace{1cm}
\end{align*}, style="position: absolute; left: 41.08576100012119vw; top: 38.61708763782681vh; width: 56.302525101742845vw; height: 21.89788262994558vh; z-index: 1; font-size: 4vw"}

\latex{\begin{align*}

\phi ::=~& \bot ~|~ \top ~|~ spec ~|~ \lnot \phi ~|~ \phi \land \phi && {\text{(CTL - inter packet)}} \\
        |~& \mathbf{AX}\ \phi ~|~ \mathbf{EX}\ \phi ~|~ \mathbf{AF}\ \phi ~|~ \mathbf{EF}\ \phi \\
        |~& \mathbf{AG}\ \phi ~|~ \mathbf{EG}\ \phi \\
        |~& \mathbf{A}[\phi\ \mathbf{U}\ \phi] ~|~ \mathbf{E}[\phi\ \mathbf{U}\ \phi]
\end{align*}, style="position: absolute; left: 43.94942913607121vw; top: 64.74623655470313vh; width: 53.814065936016426vw; height: 21.117876354388038vh; z-index: 1; font-size: 4vw"}

## Implementation: Packet Model

<div kind="raw-html" style="position: absolute; left: 2vw; top: 15vh; width: 96vw; height: 83vh; z-index: 1">
  <style>
    .pkt-slide { display: flex; gap: 2vw; height: 100%; font-family: 'Segoe UI', Arial, sans-serif; }
    .pkt-side { flex: 1; display: flex; flex-direction: column; gap: 1vh; }
    .pkt-title { font-weight: 700; font-size: 2.8vh; text-align: center; margin-bottom: 0.5vh; }
    .pkt-box { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 6px; padding: 1.2vh 1vw; font-size: 1.9vh; line-height: 1.6; flex: 1; }
    .pkt-box code { background: #e8ecf0; padding: 0.1vh 0.4vw; border-radius: 3px; font-size: 1.7vh; }
    .pkt-box .op-label { font-weight: 600; color: #1a3a5c; }
    .pkt-cells { display: flex; align-items: center; gap: 0.3vw; margin: 0.8vh 0; }
    .pkt-cells .cell { width: 3.5vw; height: 3.5vh; border: 2px solid #3b6cb5; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 1.5vh; font-weight: 600; }
    .pkt-cells .cell.concrete { background: #dae8fc; color: #1a3a5c; }
    .pkt-cells .cell.sym { background: #fff3cd; color: #856404; border-color: #e8944a; }
    .pkt-cells .cell.inf { background: #e8944a; color: white; border-color: #c0392b; font-style: italic; }
    .pkt-list-label { font-size: 1.5vh; color: #666; font-weight: 600; margin-bottom: 0.2vh; }
  </style>
  <div class="pkt-slide">
    <div class="pkt-side">
      <div class="pkt-title">Concrete</div>
      <div class="pkt-box">
        Packet = single input list, consumed as parser progresses.
        <div class="pkt-list-label">Input:</div>
        <div class="pkt-cells">
          <div class="cell concrete">v<sub>1</sub></div>
          <div class="cell concrete">v<sub>2</sub></div>
          <div class="cell concrete">v<sub>3</sub></div>
          <div class="cell concrete">v<sub>4</sub></div>
          <div class="cell concrete">...</div>
        </div>
        <br>
        <span class="op-label">extract(hdr):</span> pop first <i>n</i> bits, bind to <code>hdr</code>.<br>
        If list empty &rarr; <code>PacketTooShort</code> error.<br><br>
        <span class="op-label">lookahead:</span> peek without consuming.<br><br>
        <span class="op-label">advance:</span> consume and discard.
      </div>
    </div>
    <div class="pkt-side">
      <div class="pkt-title">Symbolic</div>
      <div class="pkt-box">
        Two lists: <b>input</b> (read from) + <b>construction</b> (built during parsing).
        <div class="pkt-list-label">Input forms:</div>
        <div class="pkt-cells">
          <div class="cell inf">&infin;</div>
          <span style="font-size:1.6vh; color:#555;">&nbsp;fully symbolic, arbitrary length</span>
        </div>
        <div class="pkt-cells">
          <div class="cell sym">v<sub>1</sub></div>
          <div class="cell sym">v<sub>2</sub></div>
          <div class="cell sym">...</div>
          <div class="cell sym">v<sub>k</sub></div>
          <span style="font-size:1.6vh; color:#555;">&nbsp;known length</span>
        </div>
        <div class="pkt-cells">
          <div class="cell sym">v<sub>1</sub></div>
          <div class="cell sym">...</div>
          <div class="cell sym">v<sub>k</sub></div>
          <div class="cell inf">&infin;</div>
          <span style="font-size:1.6vh; color:#555;">&nbsp;prefix + arbitrary tail</span>
        </div>
        <br>
        <span class="op-label">extract:</span> if value &rarr; pop &amp; bind. If &infin; &rarr; fresh symbolic, bind &amp; add to construction list.<br><br>
        <span class="op-label">lookahead:</span> peek; if &infin; &rarr; fresh symbolic appended to input (not bound).<br><br>
        <span class="op-label">advance:</span> values move to construction list; if &infin; &rarr; fresh symbolic to construction (unbound).<br><br>
        <b>Final packet</b> = construction list ++ remaining input.
      </div>
    </div>
  </div>
</div>

## 

\center{Evaluation, style="font-size:12vh"}

## Warning about undefined behavior

\table{\begin{threeparttable}
\renewcommand{\arraystretch}{1.2}
\setlength{\tabcolsep}{5pt}
\begin{tabular}{@{}l c c c c c c c c@{}}
\toprule
\multirow{2}{*}{\textbf{Program}} & \multirow{2}{*}{\textbf{LoC}} & \multicolumn{4}{c}{\textbf{Time / Memory}} & \multicolumn{2}{c}{\textbf{N detected}} & \multirow{2}{*}{\textbf{N present}} \\
\cmidrule(lr){3-6} \cmidrule(lr){7-8}
 &  & \textbf{p4check} & \textbf{bf4} & \textbf{Aquila}\tnote{$\dagger$} & \textbf{p4v}\tnote{$\dagger$} & \textbf{p4check} & \textbf{bf4} &  \\
\midrule
calc & 139 & 0.40s / 65MiB & 0.37s / 27MiB & -- & 0.06s / 30MiB & 0 & 21 & 0 \\
ndn & 359 & 0.52s / 64MiB & 0.65s / 35MiB & -- & 3.42s / 246MiB & 0 & 11 & Unknown \\
ndn\_bugAdded & 360 & 0.53s / 65MiB & 0.67s / 34MiB & -- & -- & 1 & 11 & 1 \\
dapper & 535 & 4.68s / 503MiB & 0.86s / 47MiB & -- & 49.34s / 1051MiB & 11 & 28 & Unknown \\
flowlet\_switching & 210 & 0.47s / 65MiB & 0.22s / 30MiB & 0.04s / 204MiB & 0.06s / 31MiB & 2 & 9 & Unknown \\
NetCache~\cite{10.1145/3132747.3132764} & 1427 & 2.84s / 251MiB & 2.06s / 99MiB & 9.56s / 410MiB & 16.10s / 31MiB & 55 & 140 & Unknown \\
\bottomrule
\end{tabular}
\begin{tablenotes}
\small
\item[$\dagger$] Results obtained from prior work.
\end{tablenotes}
\end{threeparttable}, style="position: absolute; left: 3.648801618161828vw; top: 28.93192106507065vh; width: 88.57905067005053vw; height: 73.85458471772937vh; z-index: 0; font-size: 2.5vw"}

## Conclusion

<div kind="text" style="position: absolute; left: 10vw; top: 30vh; width: 57.6794561314642vw; height: 40.93647704679715vh; z-index: 10; font-size: 4vw; color: #333333"><span style="color:rgb(51, 51, 51);font-size:4.000004204286386vh">* The P4Check Grisette-based symbolic interpreter can be used to check simple properties</span><br><br><span style="color:rgb(51, 51, 51);font-size:4.000004204286386vh">* Next steps:</span><span style="font-size:4.000004204286386vh"> </span><br><span style="font-size:4.000004204286386vh"> * Instantiate a debugger when a counterexample is found</span><br><br><br><br><span style="color:rgb(51, 51, 51);font-size:4.000004204286386vh">* Future work:</span><br><span style="color:rgb(51, 51, 51);font-size:4.000004204286386vh">  * concolic execution for hash implementation</span><br><br></div>

## References

\printbibliography{style="position: absolute; left: 5vw; top: 15vh; width: 90vw; height: 75vh; z-index: 0", style="position: absolute; left: 5.540969383853569vw; top: 19.423927405735856vh; width: 73.32977002734278vw; height: 70.96915997241673vh; transform: rotate(0deg); z-index: 0; font-size: 3.5vw"}
