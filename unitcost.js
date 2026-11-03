(function addUnitCostColumns(){
'use strict';
const catalog=[['Pringles',27,13.98],['Nerd Clusters',24,29.53],['Rice Krispies',40,10.99],['Mothers Circus',30,15.64],['Miss Vickies',28,18.49],['Goldfish',30,15.99],['Chip Pack',40,22.43],['Gushers',42,22.95],['Welches',80,16],['Veggie Straw',24,32],['Oreo',60,18.65],['Skinny Pop',30,18.20],['Yoggies',30,23.99],['Skittles and Starbursts',30,27.99],['Blakes Bars',24,29.99]];
const normalize=s=>String(s||'').toLowerCase().replace(/[^a-z0-9]/g,'');
const alias={nerdsclusters:'nerdclusters',nerdsgummyclusters:'nerdclusters',ricekrispiestreats:'ricekrispies',motherscircuscookies:'motherscircus',missvickieschips:'missvickies',welchs:'welches',welchsfruitsnacks:'welches',veggiestraws:'veggiestraw',oreocookies:'oreo',blakesseedbars:'blakesbars'};
function update(){
const section=document.getElementById('tab-snacks');if(!section)return;
const table=section.querySelector('table');if(!table)return;
const th=table.querySelector('thead tr');
if(!th.querySelector('[data-unit-cost]')){
const column=document.createElement('th');column.textContent='Unit cost';column.dataset.unitCost='yes';th.insertBefore(column,th.children[3]);
}
const rows=table.querySelectorAll('tbody tr');
for(const tr of rows){
if(tr.querySelector('[data-unit-cost]'))continue;
if(!tr.querySelector('[data-snack-action="edit"]'))continue;
const name=tr.cells[0].textContent.trim(),key=alias[normalize(name)]||normalize(name);
const item=catalog.find(x=>normalize(x[0])===key);
const col=document.createElement('td');col.dataset.unitCost='yes';
col.textContent=item?'$'+(item[2]/item[1]).toFixed(3):'Set cost';
col.title=item?'Pack cost $'+item[2].toFixed(2)+' / '+item[1]+' units':'Enter pack cost and pack quantity to calculate unit cost';
tr.insertBefore(col,tr.cells[3]);
}
}
setInterval(update,1500);update();
})();
