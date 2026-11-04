/* Panther Pantry shared pack-cost reference.
   Based on the 15-product purchase table, not current stock. */
(() => {
'use strict';
const catalog=[
['Pringles',27,13.98,1],['Nerd Clusters',24,29.53,2],
['Rice Krispies',40,10.99,1],['Mothers Circus',30,15.64,1],
['Miss Vickies',28,18.49,2],['Goldfish',30,15.99,1],
['Chip Pack',40,22.43,2],['Gushers',42,22.95,2],
['Welches',80,16.00,1],['Veggie Straw',24,32.00,2],
['Oreo',60,18.65,1],['Skinny Pop',30,18.20,1],
['Yoggies',30,23.99,1],['Skittles and Starbursts',30,27.99,2],
['Blakes Bars',24,29.99,2]];
const aliases={
 pringles:['sour cream pringles','original pringles','cheddar pringles'],
 nerdclusters:['nerds clusters','nerds gummy clusters'],
 ricekrispies:['rice krispeies','rice krispies treats','rice krispie treats'],
 motherscircus:["mother's cookies",'mothers cookies','mothers circus cookies'],
 missvickies:['jalapeno kettle','jalapeno kettle chips','miss vickies kettle chips'],
 goldfish:['goldfish crackers'],
 chippack:['smartfood white chedder','smartfood white cheddar',
  "cool ranch dorito's",'cool ranch doritos',
  "sun chip's",'sun chips',
  "nacho cheese dorito's",'nacho cheese doritos',
  "sour cream lay's",'sour cream lays',
  'pretzels','cheeto puffs'],
 gushers:['fruit gushers'],
 welches:["welch's","welch's fruit snacks",'welchs fruit snacks'],
 veggiestraw:['veggie straws'],
 oreo:["oreo's",'oreos','oreo cookies'],
 skinnypop:['skinny popcorn'],
 skittlesandstarbursts:['red starburst','original starburst','tropical skittles',
  'sour skittles','wild berry skittles','original skittles',
  'skittles starbursts'],
 blakesbars:['donut breakfast bae','donut breakfast bar',
  'blueberry breakfast bar','cinnamon roll breakfast bar','blakes seed bars']
};
const normalize=name=>String(name||'').toLowerCase().replace(/[^a-z0-9]/g,'');
const lookup=new Map();
for(const row of catalog)lookup.set(normalize(row[0]),row);
for(const [key,labels] of Object.entries(aliases)){
 const row=lookup.get(key);
 if(row)labels.forEach(label=>lookup.set(normalize(label),row));
}
window.PANTRY_PRICE_BOOK=Object.freeze({
 catalog,
 normalize,
 find:name=>lookup.get(normalize(name))||null
});
})();
