import qrcode from "qrcode-generator";

// Black on white with a 4-module quiet zone regardless of theme, so phone
// cameras read it from a dark page too.
export function QRCode({ text, size = 220, label }: { text: string; size?: number; label: string }) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const quiet = 4;
  let path = "";
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (qr.isDark(y, x)) path += `M${x + quiet} ${y + quiet}h1v1h-1z`;
    }
  }
  const w = n + quiet * 2;
  return (
    <svg className="qr" role="img" aria-label={label} width={size} height={size} viewBox={`0 0 ${w} ${w}`} shapeRendering="crispEdges">
      <rect width={w} height={w} fill="#fff" />
      <path d={path} fill="#000" />
    </svg>
  );
}
