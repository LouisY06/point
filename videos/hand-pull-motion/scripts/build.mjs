import fs from 'node:fs';
const html=`<!doctype html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=780,height=920"><script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script><style>*{margin:0;box-sizing:border-box}html,body{width:780px;height:920px;overflow:hidden;background:transparent}#stage{width:100%;height:100%;position:relative}#hand-canvas{width:100%;height:100%;position:absolute;inset:0}#hand-source{position:absolute;width:0;height:0;opacity:0}</style></head><body><div id="stage" data-composition-id="hand-pull" data-start="0" data-duration="2.3" data-width="780" data-height="920" data-fps="30"><canvas class="clip" data-start="0" data-duration="2.3" data-track-index="0" id="hand-canvas" width="780" height="920" data-layout-ignore="true"></canvas><img id="hand-source" src="assets/hand.png" alt="" data-layout-ignore="true"></div>`;
const motion=fs.readFileSync('scripts/motion.js','utf8');
fs.writeFileSync('index.html',html+'<script>\n'+motion+'\n</script></body></html>');
fs.writeFileSync('preview/index.html',html+'<script>window.PREVIEW=true;</script><script>\n'+motion+'\n</script></body></html>');
