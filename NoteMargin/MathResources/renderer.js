'use strict';
(() => {
 const answer = document.getElementById('answer');
 const md = window.markdownit({html:false, linkify:false, breaks:false, typographer:false});
 let revision = 0;
 const options = {throwOnError:false, trust:false, strict:'error', maxExpand:500, maxSize:15};
 function closing(source, delimiter, start) {
  let end = source.indexOf(delimiter, start);
  while (end !== -1) {
   let backslashes = 0;
   for (let p = end - 1; p >= 0 && source[p] === '\\'; p--) backslashes++;
   if (backslashes % 2 === 0) return end;
   end = source.indexOf(delimiter, end + delimiter.length);
  }
  return -1;
 }
 function delimiter(source, pos) {
  for (const [open, close, display] of [['\\[','\\]',true],['\\(','\\)',false],['$$','$$',true],['$','$',false]]) {
   if (source.startsWith(open, pos)) return {open,close,display};
  }
  return null;
 }
 md.inline.ruler.before('escape','note_math',(state,silent) => {
  const start = state.pos, d = delimiter(state.src,start);
  if (!d) return false;
  if (d.open === '$' && /\s/.test(state.src[start+1] || ' ')) return false;
  const end = closing(state.src,d.close,start+d.open.length);
  if (d.open === '$' && end !== -1 && (/\s/.test(state.src[end-1]) || /\d/.test(state.src[end+1] || ''))) return false;
  if (!silent) {
   const token = state.push(end === -1 ? 'text' : 'note_math','',0);
   token.content = end === -1 ? state.src.slice(start) : state.src.slice(start+d.open.length,end);
   token.meta = {display:d.display};
  }
  state.pos = end === -1 ? state.posMax : end+d.close.length;
  return true;
 });
 // Display math can span blank lines. Code fences and code spans keep their
 // normal Markdown meaning and are never converted into equations.
 md.block.ruler.before('fence','note_math_block',(state,startLine,endLine,silent) => {
  const start = state.bMarks[startLine]+state.tShift[startLine];
  if (state.sCount[startLine]-state.blkIndent >= 4) return false;
  const d = delimiter(state.src,start);
  if (!d?.display) return false;
  const end = closing(state.src,d.close,start+d.open.length);
  if (end === -1 || end >= state.bMarks[endLine]) return false;
  let last = startLine;
  while (last+1 < endLine && state.bMarks[last+1] <= end) last++;
  if (state.src.slice(end+d.close.length,state.eMarks[last]).trim()) return false;
  if (silent) return true;
  const token = state.push('note_math_block','',0);
  token.content = state.src.slice(start+d.open.length,end); token.meta = {display:true};
  token.block = true; token.map = [startLine,last+1]; state.line = last+1;
  return true;
 },{alt:['paragraph','reference','blockquote','list']});
 function renderMath(tokens,index) {
  const token = tokens[index], display = token.meta.display;
  let html;
  try { html = katex.renderToString(token.content,{...options,displayMode:display}); }
  catch (_) { html = md.utils.escapeHtml(token.content); }
  return `<span class="${display ? 'math-display' : 'math-inline'}">${html}</span>`;
 }
 md.renderer.rules.note_math = renderMath;
 md.renderer.rules.note_math_block = renderMath;
 // No answer text may create external requests or navigation elements.
 md.renderer.rules.image = (tokens,index) => md.utils.escapeHtml(tokens[index].content);
 md.renderer.rules.link_open = () => '<span class="link-text">';
 md.renderer.rules.link_close = () => '</span>';
 function reportSize() {
  const height = Math.ceil(answer.getBoundingClientRect().height)+2;
  window.webkit?.messageHandlers?.size?.postMessage({height,revision});
 }
 window.drawAnswer = (source,version=0,fontSize=17,theme='light') => {
  revision = version;
  document.documentElement.style.fontSize = Math.max(12,Math.min(48,fontSize))+'px';
  document.documentElement.style.colorScheme = theme === 'dark' ? 'dark' : 'light';
  answer.innerHTML = md.render(source);
  requestAnimationFrame(reportSize);
 };
 window.drawMath = expression => {
  answer.replaceChildren();
  const node = document.createElement('span');node.className='math-display';answer.append(node);
  try { katex.render(expression,node,{...options,displayMode:true}); }
  catch (_) { node.textContent=expression; }
  requestAnimationFrame(reportSize);
 };
 new ResizeObserver(reportSize).observe(answer);
 document.fonts.ready.then(reportSize);
})();
