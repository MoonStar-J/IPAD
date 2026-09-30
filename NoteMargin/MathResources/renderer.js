'use strict';
window.drawMath = function(expression) {
 const node = document.getElementById('math');
 try { katex.render(expression, node, {displayMode:true, throwOnError:false, trust:false, strict:'error', maxExpand:500, maxSize:15}); }
 catch (_) { node.textContent = expression; }
 requestAnimationFrame(() => window.webkit.messageHandlers.size.postMessage(document.body.scrollHeight + 8));
};
