#!/usr/bin/env python3
"""Run extracted upstream functions, with elementary coordinate/scene adapters.
Usage: python3 scripts/check_shape_editing_reference.py SOURCE_DIR NODE OUTPUT_JSON
SOURCE_DIR contains the pinned raw .ts files, COMMIT and MIT LICENSE.
This does not run the full Excalidraw application, binding, snapping or renderer.
"""
import json, pathlib, subprocess, sys, tempfile
root, node, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
sha = 'ed10ac7dca7e40f3f4a31269b4bfba980d0db41e'
assert (root/'COMMIT').read_text().strip() == sha
resize=(root/'resizeElements.ts').read_text(); drag=(root/'dragElements.ts').read_text(); line=(root/'linearElementEditor.ts').read_text()
def section(text, start, end): return text[text.index(start):text.index(end,text.index(start))]
functions='\n'.join([
 section(resize,'export const getResizeOffsetXY =','export const getResizeArrowDirection ='),
 section(resize,'const getResizeAnchor =','export const resizeSingleElement ='),
 section(resize,'const getNextSingleWidthAndHeightFromPointer =','const getNextMultipleWidthAndHeightFromPointer ='),
 section(drag,'const updateElementCoords =','export const getDragOffsetXY =')])
create=section(line,'  static createPointAt(','  static getNormalizeElementPointsAndCoords(').rsplit('/**',1)[0]
move=section(line,'  static movePoints(','  static shouldAddMidpoint(')
# Source computations are unmodified. Adapters only supply geometric primitives,
# absolute bounds and a scene mutation sink, for unbound/no-grid/non-polygon input.
adapters='''
const pointFrom = (x,y) => [x,y];
const pointCenter = (a,b) => [(a[0]+b[0])/2,(a[1]+b[1])/2];
const pointRotateRads = (p,c,a) => [(p[0]-c[0])*Math.cos(a)-(p[1]-c[1])*Math.sin(a)+c[0],(p[0]-c[0])*Math.sin(a)+(p[1]-c[1])*Math.cos(a)+c[1]];
const getElementAbsoluteCoords = e => [e.x,e.y,e.x+e.width,e.y+e.height];
const getResizedElementAbsoluteCoords = (e,w,h) => [e.x,e.y,e.x+w,e.y+h];
const getGridPoint = (x,y,grid) => {if(grid!==null)throw Error('unsupported grid');return [x,y];};
const isLineElement = e => true, isElbowArrow = e => false;
'''
body='''
const cases=[]; const handles=['nw','ne','se','sw'];
for (const angle of [0,0.31,1.1,-0.8]) for(const size of [[80,80],[160,65],[61,132]]) for(let corner=0;corner<4;corner++) for(const ratio of [[1,1],[1.8,1.2],[0.3,0.8]]) {
 const e={id:'shape',x:120,y:90,width:size[0],height:size[1],angle};
 const center=[e.x+e.width/2,e.y+e.height/2];
 const corners=[[e.x,e.y],[e.x+e.width,e.y],[e.x+e.width,e.y+e.height],[e.x,e.y+e.height]].map(p=>pointRotateRads(p,center,angle));
 const anchor=corners[(corner+2)%4], handle=corners[corner], grab=[handle[0]+3,handle[1]-5];
 const offset=getResizeOffsetXY(handles[corner],[e],new Map(),...grab);
 const delta=pointRotateRads([(corner===1||corner===2?1:-1)*e.width*ratio[0],(corner===2||corner===3?1:-1)*e.height*ratio[1]],[0,0],angle);
 const pointer=[anchor[0]+delta[0]+offset[0],anchor[1]+delta[1]+offset[1]];
 const dims=getNextSingleWidthAndHeightFromPointer(e,e,handles[corner],pointer[0]-offset[0],pointer[1]-offset[1],{shouldMaintainAspectRatio:true,shouldResizeFromCenter:false});
 const origin=getResizedOrigin([e.x,e.y],e.width,e.height,dims.nextWidth,dims.nextHeight,angle,handles[corner],true,false);
 cases.push({center,width:e.width,height:e.height,angle,corner,grab,pointer,expectedCenter:[origin.x+dims.nextWidth/2,origin.y+dims.nextHeight/2],expectedWidth:dims.nextWidth,expectedHeight:dims.nextHeight,offset});
}
const translations=[], endpoints=[];
for(let i=0;i<100;i++) {
 const original={id:'a',x:20,y:40},e={...original}, delta={x:Math.sin(i)*90,y:Math.cos(i)*70};
 updateElementCoords({originalElements:new Map([['a',original]])},e,{mutateElement:(e,u)=>Object.assign(e,u)},delta);
 translations.push({start:[200,400],pointer:[200+delta.x,400+delta.y],original:[20,40],expected:[e.x,e.y]});
 const a=[20,40], pointer=[Math.sin(i)*300,Math.cos(i)*200],offset=[3,-2];
 const l={x:a[0],y:a[1],width:100,height:80,angle:0,points:[[0,0],[100,80]],polygon:false};
 const p=LinearElementEditor.createPointAt(l,new Map(),pointer[0]-offset[0],pointer[1]-offset[1],null);
 LinearElementEditor.movePoints(l,{},new Map([[1,{point:p,isDragging:true}]]));
 endpoints.push({pointer,offset,expected:[l.points[1][0]+a[0],l.points[1][1]+a[1]],start:[l.x,l.y]});
}
console.log(JSON.stringify({sha:'SHA',scope:'Extracted original functions with coordinate/scene adapters; not the full Excalidraw application',cases,translations,endpoints}));
'''.replace('SHA',sha)
code='/* '+(root/'LICENSE').read_text()+' */\n'+adapters+functions+'\nclass LinearElementEditor {\n'+create+move+'\nstatic _updatePoints(e,scene,points,ox,oy){if(ox||oy)throw Error("origin branch out of scope");e.points=points;}\n}\n'+body
with tempfile.TemporaryDirectory(prefix='shape-upstream-') as folder:
 path=pathlib.Path(folder)/'reference.mts';path.write_text(code)
 result=subprocess.run([node,str(path)],text=True,capture_output=True,check=True)
 data=json.loads(result.stdout);output.write_text(json.dumps(data,indent=2))
 print(f'Executed pinned upstream functions: {len(data["cases"])} resize, {len(data["translations"])} move, {len(data["endpoints"])} endpoint cases -> {output}')
