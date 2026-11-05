import{C as e,S as t,n,x as r,y as i}from"./controls-B63Cm3l2.js";import{$ as a,I as o}from"./discovery-DQoIaMBt.js";/* empty css                 */import{t as s}from"./page-title-Cwq92KvE.js";import{t as c}from"./chessboard-DmgqraN3.js";function l(e,a){let o=r`${e.toc.map(e=>r`<p class="label docs-group">${e.group}</p><ul>${e.sections.map(e=>r`<li><a class="${i(`docs-link`,{"is-on":e.id===a})}" href="#/docs/${e.id}" data-docs-link="${e.id}">${e.title}</a></li>`)}</ul>`)}`;return r`<div class="docs">
    <nav class="docs-nav" aria-label="Contents"><details class="docs-contents" open data-docs-contents><summary class="label">Contents</summary>${o}</details></nav>
    <article class="docs-body">
      <div class="docs-tools">${n({label:`Copy page as Markdown`,size:`sm`,data:{"docs-copy":``}})}<a class="text-link" href="docs/llms.txt" target="_blank" rel="noopener">llms.txt</a></div>
      <div class="prose">${t(e.html)}</div>
    </article>
  </div>`}function u(e,t,r){let i=(e,t)=>navigator.clipboard?.writeText(e).then(()=>{let e=t.querySelector(`.key-label`)??t,n=e.textContent;e.textContent=`Copied`,setTimeout(()=>{e.textContent=n},1200)},()=>void 0);for(let t of e.querySelectorAll(`.docs-code`))t.insertAdjacentHTML(`beforeend`,n({label:`Copy`,size:`sm`,data:{"code-copy":``}}).value);let a=e.querySelector(`[data-docs-contents]`),o=matchMedia(`(max-width: 900px)`);a&&o.matches&&(a.open=!1);let s=t=>e.querySelectorAll(`[data-docs-link]`).forEach(e=>e.classList.toggle(`is-on`,e.dataset.docsLink===t)),c=(t,n)=>{let r=e.querySelector(`#${CSS.escape(t)}`);r&&(r.scrollIntoView({behavior:n&&!matchMedia(`(prefers-reduced-motion: reduce)`).matches?`smooth`:`auto`}),s(t))},l=e=>{let n=e.target,r=n.closest(`[data-code-copy]`);if(r)return void i(r.closest(`.docs-code`)?.querySelector(`code`)?.textContent??``,r);let s=n.closest(`[data-docs-copy]`);if(s)return void i(t.markdown,s);let l=n.closest(`a[href^="#/docs/"]`);if(!l||e.metaKey||e.ctrlKey||e.shiftKey)return;e.preventDefault();let u=l.getAttribute(`href`).slice(7);history.pushState(null,``,`#/docs/${u}`),a&&o.matches&&(a.open=!1),c(u,!0)};e.addEventListener(`click`,l);let u=[...e.querySelectorAll(`.prose h2[id]`)],d=new IntersectionObserver(e=>{let t=e.filter(e=>e.isIntersecting).sort((e,t)=>e.boundingClientRect.top-t.boundingClientRect.top)[0];t&&s(t.target.id)},{rootMargin:`0px 0px -70% 0px`});return u.forEach(e=>d.observe(e)),r&&requestAnimationFrame(()=>c(r,!1)),()=>{e.removeEventListener(`click`,l),d.disconnect()}}var d=`e4 e5 Nf3 Nc6`,f=[{label:`Trade`,at:`White to move`,title:`Buy the token of the team you back.`,text:`White is to move. Buying White’s token is a bid for this move. It is a normal buy, so you keep the tokens, and part of its fee fills the reward pools.`},{label:`Bid`,at:`White to move`,title:`The biggest bid owns the move.`,text:`A new top bid must pay more than 10% over the current one. Bidding stays open for about 36 seconds after the previous move is played; then the move is fixed.`},{label:`Move`,at:`The move played`,title:`The engine plays the move.`,text:`The hash of the window’s last block seeds the engine, so nobody knows the move while bidding. The next trade, from either team, plays it. A bigger bid plays stronger; nobody picks the square.`},{label:`Prize`,at:`Checkmate`,title:`Checkmate wins the jackpot.`,text:`Rd8 is checkmate. Its owner wins from the losing team’s reward pool, paid in that team’s token. Every trade in the game grows the prize.`}],p=e=>`abcdefgh`.indexOf(e[0])+(Number(e[1])-1)*8;function m(e){let t=e===3?new a(`6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1`):new a;if(e<3)for(let e of d.split(` `))t.move(e);let n=e===2?t.move(`Bc4`):e===3?t.move(`Rd8#`):t.history({verbose:!0}).at(-1);return{pieces:o(t.fen()),...n?{last:{from:p(n.from),to:p(n.to)}}:{},...e===3?{check:p(`g8`)}:{}}}var h=()=>r`<div class="walkthrough"><div class="walk-board"></div><div class="walk-body"><span class="label" data-walk-at></span>
  <div class="walk-steps" role="group" aria-label="Steps in a turn">${f.map(({label:e},t)=>n({label:`${t+1}. ${e}`,size:`sm`,pressed:t===0,data:{lesson:t}}))}</div>
  <div class="walk-explanation" aria-live="polite"><h3></h3><p></p></div></div></div>`;function g(e){let t=new c(e.querySelector(`.walk-board`),`Example`),n=n=>{let r=Math.max(0,Math.min(f.length-1,n));t.show(m(r)),e.querySelectorAll(`[data-lesson]`).forEach(e=>e.setAttribute(`aria-pressed`,String(Number(e.dataset.lesson)===r))),e.querySelector(`[data-walk-at]`).textContent=`Example / ${f[r].at}`,e.querySelector(`h3`).textContent=f[r].title,e.querySelector(`.walk-explanation p`).textContent=f[r].text},r=new AbortController;return e.addEventListener(`click`,e=>{let t=e.target.closest(`[data-lesson]`);t&&n(Number(t.dataset.lesson))},{signal:r.signal}),n(0),()=>r.abort()}var _={html:`<h2 id="introduction"><a class="docs-anchor" href="#/docs/introduction" aria-label="Link to this section">#</a>Introduction</h2>
<p>IMDuel is a Uniswap v4 hook that plays chess. Every pool that uses it is a <strong>duel</strong>: its two tokens are two teams, and they play an endless series of chess games against each other.</p>
<ul>
<li><strong>Buying a token is a bid</strong> for its team&#39;s next move. The biggest buy owns the move.</li>
<li><strong>An onchain engine plays the move.</strong> Nobody picks the square; a bigger buy makes the engine play stronger.</li>
<li><strong>Checkmate wins the jackpot.</strong> The owner of the mating move wins from the losing team&#39;s reward pool.</li>
</ul>
<p>A bid is an ordinary buy: you keep the tokens you bought, and the move comes with it. There is no ticket, no deposit and no separate call.</p>
<p>The main duel is <strong>$IMDUEL / $IMD</strong> on Ethereum. Anyone can create a duel of another token against $IMD or $IMDUEL. The hook, the engine and the staking vault have no owner, no admin key, no pause and no upgrade.</p>
<p>$IMDUEL holders can also <a href="#/docs/staking">stake</a> it for a share of the main duel&#39;s trading fees.</p>
<p>IMDuel is experimental. A bigger buy plays a stronger move but guarantees no mate, win or profit, and token prices move. Trade only what you can afford to lose.</p>
<h2 id="quick-start"><a class="docs-anchor" href="#/docs/quick-start" aria-label="Link to this section">#</a>Quick start</h2>
<ol>
<li><strong>Get a token to pay with.</strong> In the main duel you buy $IMDUEL with $IMD, or $IMD with $IMDUEL. $IMD trades on Uniswap against ETH. You also need ETH for gas.</li>
<li><strong>Connect.</strong> Press Connect in the header and choose your wallet.</li>
<li><strong>Open a duel.</strong> <a href="#/duels">Duels</a> lists every duel; the main duel is first. Its page shows the board, whose move it is, the top bid and what a checkmate wins now.</li>
<li><strong>Buy for a team.</strong> In the Trade panel, pick the team you back and an amount. The panel shows whether your buy takes the top bid and how strong the move would be.</li>
<li><strong>Watch the move.</strong> About 36 seconds after the previous move, bidding closes and the move is fixed; the next trade in the pool plays it.</li>
</ol>
<h2 id="how-a-game-works"><a class="docs-anchor" href="#/docs/how-a-game-works" aria-label="Link to this section">#</a>How a game works</h2>
<div data-walkthrough></div><h3 id="teams"><a class="docs-anchor" href="#/docs/teams" aria-label="Link to this section">#</a>Teams</h3>
<p>Each of a duel&#39;s two tokens is a team: buy $IMDUEL to play for $IMDUEL, buy $IMD to play for $IMD. You pay for one team&#39;s token with the other&#39;s, so every trade plays for exactly one team. The teams swap colours every game; in a duel&#39;s first game White is the duel&#39;s own token and Black the token it is paired against (in the main duel, $IMDUEL plays White).</p>
<h3 id="bidding"><a class="docs-anchor" href="#/docs/bidding" aria-label="Link to this section">#</a>Bidding</h3>
<p>Every buy of a team&#39;s token bids for that team&#39;s next move: the move being decided if it is that team&#39;s turn, otherwise its following move. There is no minimum, and any app or aggregator can send the trade.</p>
<ul>
<li><strong>The top bid owns the move.</strong> Bids are compared by what the trade paid. To take the top spot, a buy must pay more than 10% over the current top bid; smaller buys just trade.</li>
<li><strong>The owner</strong> is the address the trade names. Trading on this site names you; a trade from another app names the wallet that signed it.</li>
<li><strong>Bidding lasts 3 blocks</strong> after the previous move is played, about 36 seconds on Ethereum. If a move&#39;s first bid comes in the last of those blocks or later, bidding stays open for 3 blocks from that bid, so the other bidders can always answer.</li>
<li><strong>Bids carry over.</strong> A bid for a move the game never reaches owns its team&#39;s first move of the next game.</li>
</ul>
<h3 id="playing-the-move"><a class="docs-anchor" href="#/docs/playing-the-move" aria-label="Link to this section">#</a>Playing the move</h3>
<p>When bidding closes, the hash of the window&#39;s last block seeds the engine. That hash doesn&#39;t exist while anyone can still bid, so no bidder can know which move their bid will play. Once that block is mined the move is fixed, and the site shows it.</p>
<p>The first trade after that plays the move. It can come from either team and be any size; it doesn&#39;t change the move, but it pays the engine&#39;s gas (see <a href="#/docs/gas">Gas</a>).</p>
<p>If the side to move gets no bid for 10 minutes, a trade by the other team opens that move at 0% strength, owned by nobody. A real bid in the same block takes it over. A move owned by nobody wins nothing, even if it mates.</p>
<h3 id="game-end"><a class="docs-anchor" href="#/docs/game-end" aria-label="Link to this section">#</a>Game end</h3>
<p>A game ends by checkmate or a draw. The board resets, the teams swap colours and the next trade starts a new game; the reward pools carry over. Draws are automatic:</p>
<ul>
<li>stalemate;</li>
<li>too few pieces to mate (two kings, or a king and one knight or bishop against a king);</li>
<li>the same position for the third time within the last sixteen half-moves (the start position counts from any distance);</li>
<li>60 half-moves without a capture or pawn move;</li>
<li>200 half-moves in total;</li>
<li>the engine failing twice on one position (it never has).</li>
</ul>
<h2 id="strength"><a class="docs-anchor" href="#/docs/strength" aria-label="Link to this section">#</a>Strength</h2>
<p>Strength is how hard the engine thinks about a move. It comes from the tokens the owning buy received, compared with its own team&#39;s reward pool, which is in the same token:</p>
<table>
<thead>
<tr>
<th>Tokens received, as a share of the team&#39;s reward pool</th>
<th>Strength</th>
</tr>
</thead>
<tbody><tr>
<td>0.1% or less</td>
<td>0%</td>
</tr>
<tr>
<td>1%</td>
<td>30%</td>
</tr>
<tr>
<td>10%</td>
<td>60%</td>
</tr>
<tr>
<td>The whole reward pool or more</td>
<td>90% (the cap)</td>
</tr>
</tbody></table>
<p>Strength reads no price and no liquidity, so nothing outside the game can make a bid stronger or weaker. The one thing that changes it is the size of the reward pool: an empty pool plays at the cap, so right after launch and after a mate most moves play strong until the pool grows.</p>
<p>At 0% the engine plays like a beginner who still sees captures and checks; near the cap, like a strong amateur. Every strength keeps a few seeded mistakes, more at low strength, so games stay lively: even a whale&#39;s move can miss a mate.</p>
<p>The engine is a contract on Ethereum and runs inside the trade that plays the move. It scores every legal move for material, position, pressure on the enemy king and the risk it leaves, and always weighs captures and checks; higher strength gives the leading candidates more second looks. With a lone enemy king left it plays at full effort to finish the game, and the longer a game goes without a capture or pawn move, the harder it pushes for progress.</p>
<h2 id="checkmate-rewards"><a class="docs-anchor" href="#/docs/checkmate-rewards" aria-label="Link to this section">#</a>Checkmate rewards</h2>
<p>Checkmate wins the jackpot. The owner of the mating move wins from the <strong>losing</strong> team&#39;s reward pool, paid in the losing team&#39;s token: mate for $IMDUEL and you win $IMD; mate for $IMD and you win $IMDUEL. The winning team&#39;s own pool is untouched.</p>
<p>The prize is the smallest of three amounts:</p>
<ol>
<li>a quarter of the losing team&#39;s reward pool;</li>
<li>2x what the mating bid paid;</li>
<li>what this game&#39;s trades paid into the losing team&#39;s reward pool.</li>
</ol>
<p><strong>Example.</strong> $IMDUEL mates. The $IMD reward pool holds 10,000 $IMD, this game&#39;s trades paid 3,000 $IMD into it, and the mating bid paid 1,000 $IMD. The prize is the smallest of 2,500, 2,000 and 3,000: <strong>2,000 $IMD</strong>. The other 8,000 stay in the pool.</p>
<p>So every trade in the game grows the prize, and a bigger bid can win more. Only the mating move&#39;s owner is paid; captures, checks and draws leave the pools to grow until the next mate. A mate in one is visible to everyone, so expect a race for it: bots may bid in the window&#39;s last block, and their bids are buys like any other.</p>
<h3 id="withdrawing"><a class="docs-anchor" href="#/docs/withdrawing" aria-label="Link to this section">#</a>Withdrawing</h3>
<p>The prize is recorded for the owner when the mate is played; nothing is sent inside a trade. <strong>Payouts</strong>, under each duel&#39;s board, shows what is yours with a Withdraw button, and rewards wait as long as you like. Anyone can call <code>withdraw</code> for an owner, but it only ever pays that owner; <code>withdrawTo</code> lets the owner send to another address. A withdrawal leaves 1 wei behind, which makes the next reward cheaper to record; the site counts it as nothing.</p>
<h2 id="fees-and-reward-pools"><a class="docs-anchor" href="#/docs/fees-and-reward-pools" aria-label="Link to this section">#</a>Fees and reward pools</h2>
<p>Every swap in a duel pays two fees:</p>
<table>
<thead>
<tr>
<th>Fee</th>
<th>Rate</th>
<th>Goes to</th>
</tr>
</thead>
<tbody><tr>
<td>Hook fee</td>
<td>0.75%</td>
<td>0.65% to the two reward pools, 0.1% burns $IMDUEL (see <a href="#/docs/burn">Burn</a>)</td>
</tr>
<tr>
<td>Pool fee</td>
<td>1.25% in the main duel</td>
<td>the pool&#39;s liquidity: 1% to the <a href="#/docs/staking">fee router</a> ($IMDUEL to stakers, $IMD to the team), 0.25% to the IMD network</td>
</tr>
</tbody></table>
<p>A trade in the main duel costs 2% in fees, plus gas and price impact. Other duels charge the same hook fee and the pool fee their creator chose. Every swap emits Uniswap&#39;s standard <code>HookSwap</code> event with the hook fee, so explorers show the full cost.</p>
<p><strong>Reward pools.</strong> Each duel has two, one per team, in that team&#39;s token.</p>
<ul>
<li><strong>Filled by every trade.</strong> Half of the 0.65% is taken from what a trade pays, into that token&#39;s pool, and half from what it buys, into the other token&#39;s pool, so every trade feeds both pools by about the same value.</li>
<li><strong>Emptied only by checkmate.</strong> A mate&#39;s prize is the only thing that leaves a pool, and it never takes more than the game paid in, so a pool never ends a game smaller than it started.</li>
<li><strong>Anyone can add to one</strong> with the hook&#39;s <code>fundChest</code>. That raises what a mate against that team wins and makes that team&#39;s bids weaker, since strength is a share of the pool.</li>
</ul>
<h2 id="imduel"><a class="docs-anchor" href="#/docs/imduel" aria-label="Link to this section">#</a>$IMDUEL</h2>
<p>$IMDUEL is IMDuel&#39;s token, launched on Ethereum by the IMD swarm together with the hook.</p>
<table>
<thead>
<tr>
<th></th>
<th></th>
</tr>
</thead>
<tbody><tr>
<td>Contract</td>
<td><code>0xc012b8Db13C57beCd950eEfB70540e6f973A3C73</code></td>
</tr>
<tr>
<td>Supply</td>
<td>1,000,000,000, fixed: no minting, no tax, plain transfers</td>
</tr>
<tr>
<td>Pair</td>
<td>$IMDUEL / $IMD, the main duel</td>
</tr>
<tr>
<td>Opening price</td>
<td>2,500 $IMD for the whole supply (1 $IMD = 400,000 $IMDUEL)</td>
</tr>
</tbody></table>
<p>$IMDUEL is a team in the main duel and in every duel paired against it, and the hook fee of every duel holding $IMDUEL burns it. Tokens named IMDuel at any other address are not $IMDUEL.</p>
<h3 id="distribution"><a class="docs-anchor" href="#/docs/distribution" aria-label="Link to this section">#</a>Distribution</h3>
<table>
<thead>
<tr>
<th>Share</th>
<th>Goes to</th>
</tr>
</thead>
<tbody><tr>
<td>80%</td>
<td>The main duel&#39;s pool, single-sided: everyone buys from it</td>
</tr>
<tr>
<td>8%</td>
<td>IMD seats connected at launch, shared equally (the swarm&#39;s airdrop)</td>
</tr>
<tr>
<td>2%</td>
<td>Wallets that worked on the launch (the swarm&#39;s airdrop)</td>
</tr>
<tr>
<td>10%</td>
<td>The launch wallet <code>0x6AA3…5B23</code>: the team, and seeding new features and chain expansions</td>
</tr>
</tbody></table>
<h3 id="burn"><a class="docs-anchor" href="#/docs/burn" aria-label="Link to this section">#</a>Burn</h3>
<p>0.1% of every swap is taken in $IMDUEL wherever a duel holds $IMDUEL, the main duel included, and burned. A duel paired with $IMD that holds no $IMDUEL takes its 0.1% in $IMD and adds it to the main duel&#39;s $IMD reward pool instead.</p>
<p>The burn is owed to <code>0x…dEaD</code> in the hook and sent there by anyone calling <code>withdraw(0x…dEaD, IMDUEL)</code>. The main duel&#39;s page shows the total burned.</p>
<h2 id="staking"><a class="docs-anchor" href="#/docs/staking" aria-label="Link to this section">#</a>Staking</h2>
<p>Stake $IMDUEL in the staking vault and receive <strong>sIMDUEL</strong>, a share of everything the vault holds. The vault pays stakers from a reward reserve, so each sIMDUEL is redeemable for more $IMDUEL over time. There is no lock-up, no fee and nothing to claim: rewards compound into the share value every second, and you can unstake at any time.</p>
<p>The vault is a standard <a href="https://eips.ethereum.org/EIPS/eip-4626">ERC-4626</a> tokenized vault built on OpenZeppelin&#39;s implementation. sIMDUEL is an ERC-20 with 18 decimals and can be transferred like any other token; whoever holds it can redeem it.</p>
<h3 id="shares"><a class="docs-anchor" href="#/docs/shares" aria-label="Link to this section">#</a>Shares</h3>
<p>When you stake, the vault mints sIMDUEL at the current share value: staking 1,000 $IMDUEL while 1 sIMDUEL is worth 1.25 $IMDUEL mints 800 sIMDUEL. The number of shares you hold doesn&#39;t change after that; what grows is what each one is worth.</p>
<pre class="docs-code"><code>share value = total staked / sIMDUEL supply</code></pre>
<p><strong>Total staked</strong> is every $IMDUEL deposited plus every reward released so far. The share value only rises: rewards add to the total staked without minting shares, and staking or unstaking moves the total staked and the supply in proportion. As in every ERC-4626 vault, conversions round in the vault&#39;s favour, by at most 1 wei.</p>
<h3 id="the-reward-reserve"><a class="docs-anchor" href="#/docs/the-reward-reserve" aria-label="Link to this section">#</a>The reward reserve</h3>
<p>Rewards come from a separate balance in the vault, the <strong>reward reserve</strong>. The reserve is not part of the share value until it is released.</p>
<ul>
<li><strong>Released continuously.</strong> The reserve releases 1% of itself a day, by the second, into the total staked. After <code>t</code> days with nothing new arriving it holds <code>reserve × 0.99^t</code>, so it halves in about 69 days. It only releases while someone besides the permanent stake is staked; until then it waits.</li>
<li><strong>Refilled by fees.</strong> Any $IMDUEL sent to the vault joins the reserve, not the stake. The main duel&#39;s trading fees arrive this way through the fee router, and future features can top it up the same way. <code>sync()</code> counts a transfer at once; otherwise it is counted at the next stake or unstake.</li>
<li><strong>Never minted.</strong> Rewards are only ever $IMDUEL that was sent to the vault. Staking creates no new supply.</li>
</ul>
<p>The reserve started with 10,000,000 $IMDUEL from the launch wallet.</p>
<h3 id="apr"><a class="docs-anchor" href="#/docs/apr" aria-label="Link to this section">#</a>APR</h3>
<p>The staking page shows the current APR: what the reserve releases in a day, over a year, divided by the total staked.</p>
<pre class="docs-code"><code>APR = reserve × 1% × 365 / total staked</code></pre>
<p>It is a snapshot, not a promise. It falls as more $IMDUEL is staked and as the reserve pays out, and rises when fees refill the reserve or stakers leave. Because rewards compound into the share value, a stake held for a year at a constant APR would earn slightly more than the APR.</p>
<h3 id="the-permanent-stake"><a class="docs-anchor" href="#/docs/the-permanent-stake" aria-label="Link to this section">#</a>The permanent stake</h3>
<p>The vault opens with 1 $IMDUEL staked on behalf of <code>0x…dEaD</code>, from the reserve, the first time <code>sync()</code> runs with at least 1 $IMDUEL in it. Those shares can never be redeemed. They keep sIMDUEL in existence at all times, so the vault is never empty, and no first depositor can inflate the share value against those who follow (the ERC-4626 inflation attack). Until the permanent stake exists, the vault accepts no deposits.</p>
<p>The permanent stake earns like any other, in proportion to its size, but only alongside other stakers: while it is the only stake, the reserve pays out nothing and waits for the first staker. Beside a very small stake it takes most of each payout, so the team&#39;s 1,000,000 $IMDUEL stays staked, which keeps its share at about a millionth. The staking page counts it as burned.</p>
<h3 id="the-fee-router"><a class="docs-anchor" href="#/docs/the-fee-router" aria-label="Link to this section">#</a>The fee router</h3>
<p>The main duel&#39;s pool fee is 1.25%. The IMD launch factory pays 1% of it to the launch&#39;s <strong>requester</strong> and 0.25% to the IMD network. The requester is the IMDuel fee router, which forwards what it receives:</p>
<table>
<thead>
<tr>
<th>Token</th>
<th>Goes to</th>
</tr>
</thead>
<tbody><tr>
<td>$IMDUEL</td>
<td>the staking vault&#39;s reward reserve</td>
</tr>
<tr>
<td>$IMD</td>
<td>the team</td>
</tr>
</tbody></table>
<p>Fees accrue in the factory until anyone calls the router&#39;s <code>collect()</code>, which claims them and forwards both tokens in the same transaction.</p>
<p>The router&#39;s admin can hand the requester role to a new address, for example a router with a different split. A handover must be proposed first and can only be carried out 3 days later, within the 3 days after that; a proposal left longer expires and has to be made again. So every change is public in advance through the <code>Proposed</code> event. The admin can also call <code>lock()</code>, which removes the admin for good and leaves the requester with this router permanently. The admin cannot move funds or touch the vault.</p>
<h2 id="gas"><a class="docs-anchor" href="#/docs/gas" aria-label="Link to this section">#</a>Gas</h2>
<table>
<thead>
<tr>
<th>Trade</th>
<th>Typical gas</th>
</tr>
</thead>
<tbody><tr>
<td>A trade that only bids</td>
<td>about 180,000</td>
</tr>
<tr>
<td>A trade that plays a move</td>
<td>about 530,000; usually 350,000 to 650,000</td>
</tr>
</tbody></table>
<p>The trade that plays a move runs the engine, so it costs more, whoever sends it. This site sends every trade with a gas limit of 5,000,000, and you pay only for the gas used.</p>
<p>Other apps estimate gas when you confirm, and bidding can close between that estimate and the block your trade lands in; then your trade is the one that plays the move. It must have the engine&#39;s full 3,000,000 gas on hand, or it reverts with <code>NotEnoughGas</code> instead of playing a weaker move: only the gas is spent, and it can be sent again with a higher limit. Integrations should send every trade with at least 5,000,000.</p>
<h2 id="trading"><a class="docs-anchor" href="#/docs/trading" aria-label="Link to this section">#</a>Trading</h2>
<p>The site trades through Uniswap&#39;s own contracts, the Universal Router and Permit2.</p>
<ol>
<li><strong>Approve, once per token.</strong> A transaction that lets Permit2 move that token.</li>
<li><strong>Sign a permit.</strong> No gas. It lets the router spend this amount for a short time; skipped while an earlier permit still covers the trade.</li>
<li><strong>Send the trade.</strong> One transaction, with the permit inside it.</li>
</ol>
<p><strong>Slippage.</strong> Auto allows 0.5% plus the largest recent price move within one block in this pool, at most 5%. Other bids for the same move buy the same token, so trades ahead of yours in a block move your price. Whatever you allow is also what a bot trading around yours could take.</p>
<p><strong>Liquidity.</strong> The Pool switch on a duel&#39;s panel adds liquidity to its Uniswap pool. Liquidity earns the pool fee, shared by size; the hook fee goes to the game. Your position is a Uniswap position NFT in your wallet and has no effect on anyone&#39;s strength or rewards.</p>
<p>Wallets may show the value you receive as $0 until their price services list a new token; the token amount is what counts.</p>
<h2 id="creating-a-duel"><a class="docs-anchor" href="#/docs/creating-a-duel" aria-label="Link to this section">#</a>Creating a duel</h2>
<p><a href="#/create">Create a duel</a> for any ERC-20, or ETH, against $IMD or $IMDUEL. It&#39;s free apart from gas.</p>
<ol>
<li>Pick the token, the pair and the pool fee.</li>
<li>Set the starting deposits: they set the opening price and become your liquidity position.</li>
<li>Confirm. If that exact pool already exists, the site opens it instead.</li>
</ol>
<p>A new duel charges the hook fee from its first trade. It must be paired with $IMD or $IMDUEL, so its 0.1% always has somewhere to go; the hook refuses any other pair.</p>
<h2 id="staking-and-unstaking"><a class="docs-anchor" href="#/docs/staking-and-unstaking" aria-label="Link to this section">#</a>Staking and unstaking</h2>
<p><a href="#/staking">Staking</a> has one form for both directions.</p>
<ol>
<li><strong>Stake.</strong> Enter an amount of $IMDUEL, or press Max. The first stake asks for an approval of the vault, then the deposit; later stakes are a single transaction. The form shows the sIMDUEL you receive, your stake after and what it would earn a day at the current rate.</li>
<li><strong>Watch it grow.</strong> Your stake is shown in $IMDUEL and updates every second. Nothing needs to be claimed.</li>
<li><strong>Unstake.</strong> Switch to Unstake and enter an amount of sIMDUEL, or press Max to redeem every share. The $IMDUEL arrives in the same transaction.</li>
<li><strong>Fill the reserve.</strong> The Reserve tab shows the main duel&#39;s fees waiting in the fee router. Anyone can send them on, for the gas alone: the $IMDUEL goes into the reserve for every staker.</li>
</ol>
<p>The vault&#39;s standard ERC-4626 functions also stake for another address (<code>deposit(assets, receiver)</code>) and unstake to one (<code>redeem(shares, receiver, owner)</code>). Only the holder of sIMDUEL, or an address it approved, can redeem it.</p>
<h2 id="profiles-and-leaderboard"><a class="docs-anchor" href="#/docs/profiles-and-leaderboard" aria-label="Link to this section">#</a>Profiles and leaderboard</h2>
<p>Every address has a profile at <code>#/profile/0x…</code>: press an address anywhere on the site, or rest on it for a summary card. It shows what the hook counts for that address in the main duel (games, moves by piece, pieces taken, checks, castles, promotions, checkmates and amounts won) and the badges those counts earn. Names and avatars come from ENS.</p>
<p>The <a href="#/leaderboard">Leaderboard</a> ranks every main-duel player by badges, checkmates, moves, pieces taken or games. Badges are computed from the hook&#39;s counts and are not minted. Only the main duel counts.</p>
<h2 id="contracts"><a class="docs-anchor" href="#/docs/contracts" aria-label="Link to this section">#</a>Contracts</h2>
<p>All on Ethereum mainnet.</p>
<table>
<thead>
<tr>
<th>Contract</th>
<th>Address</th>
</tr>
</thead>
<tbody><tr>
<td>IMDuelHook</td>
<td><a href="https://etherscan.io/address/0xA92F72DcDd90229C32F6d51229F4cc5c916410CC"><code>0xA92F72DcDd90229C32F6d51229F4cc5c916410CC</code></a></td>
</tr>
<tr>
<td>ChessEngineV5</td>
<td><a href="https://etherscan.io/address/0xc21788F704a8b9456f7391A01d8a3D95Be215a27"><code>0xc21788F704a8b9456f7391A01d8a3D95Be215a27</code></a></td>
</tr>
<tr>
<td>$IMDUEL</td>
<td><a href="https://etherscan.io/address/0xc012b8Db13C57beCd950eEfB70540e6f973A3C73"><code>0xc012b8Db13C57beCd950eEfB70540e6f973A3C73</code></a></td>
</tr>
<tr>
<td>IMDuelStaking (sIMDUEL)</td>
<td><a href="https://etherscan.io/address/0x8EA92158b116F835a4961baEFc7e1109562DD723"><code>0x8EA92158b116F835a4961baEFc7e1109562DD723</code></a></td>
</tr>
<tr>
<td>IMDuelFeeRouter</td>
<td><a href="https://etherscan.io/address/0xf4f9Daec44cC531Abe674184bBe8191024247E23"><code>0xf4f9Daec44cC531Abe674184bBe8191024247E23</code></a></td>
</tr>
<tr>
<td>Main duel (pool id)</td>
<td><code>0xbb45eacf50b4bd8ce31e0620e14ff6e6b6375d56fce4372d3046f4a02faeae65</code></td>
</tr>
<tr>
<td>Launch wallet</td>
<td><code>0x6AA302EFf055259c9Cf177f33Ae3cBA5d4135B23</code></td>
</tr>
</tbody></table>
<p>Deployed through IMD launch 2843 (<a href="https://explorer.imd.fun/jobs/4098dafa-99b4-4c9f-97e3-430b49ea6afa">job 4098dafa</a>) at block 26,322,077. The deployed source is in <a href="https://github.com/identity-md-launches/launch-2843-launch-imduel-imduel-launch-json">the swarm&#39;s launch repository</a>. The staking vault and the fee router were deployed by the launch wallet on 4 November 2026.</p>
<h2 id="integrating"><a class="docs-anchor" href="#/docs/integrating" aria-label="Link to this section">#</a>Integrating</h2>
<p><strong>Trading.</strong> Any router or aggregator can trade a duel, and every buy bids. The owner of a bid is the address in <code>hookData</code>, 20 bytes packed or 32 bytes ABI-encoded; without it, the owner is the wallet that signed the transaction. Pass it for smart-contract wallets and relayed trades, where the signer isn&#39;t the trader. Gas limits: see <a href="#/docs/gas">Gas</a>.</p>
<pre class="docs-code"><code>hookData = abi.encodePacked(owner)   // 20 bytes
hookData = abi.encode(owner)         // 32 bytes</code></pre>
<p><strong>Reading.</strong> A duel is identified by its Uniswap pool id. Team 0 is <code>currency0</code>&#39;s, team 1 <code>currency1</code>&#39;s.</p>
<table>
<thead>
<tr>
<th>Function</th>
<th>Returns</th>
</tr>
</thead>
<tbody><tr>
<td><code>game(poolId)</code></td>
<td>the board, the side to move, both top bids, the bidding window and the last move</td>
</tr>
<tr>
<td><code>chest(poolId, team)</code></td>
<td>a team&#39;s reward pool</td>
</tr>
<tr>
<td><code>gameInflow(poolId, gameNo)</code></td>
<td>what a game&#39;s trades paid into each reward pool</td>
</tr>
<tr>
<td><code>previewMove(poolId, hash)</code></td>
<td>the move a closed window will play, given its last block&#39;s hash</td>
</tr>
<tr>
<td><code>owed(owner, currencyId)</code></td>
<td>rewards waiting to be withdrawn</td>
</tr>
<tr>
<td><code>stats(address)</code></td>
<td>a player&#39;s main-duel counts, in two packed words</td>
</tr>
<tr>
<td><code>players(i)</code>, <code>playerCount()</code></td>
<td>every address that has owned a played move in the main duel</td>
</tr>
<tr>
<td><code>MATE_SHARE_BPS</code>, <code>PAYOUT_CAP</code>, <code>MATE_INFLOW_CAP</code></td>
<td>the prize&#39;s three limits: 2,500 (a quarter), 2 (twice the bid), 1 (the game&#39;s pay-in)</td>
</tr>
</tbody></table>
<p>Events: <code>GameStarted</code>, <code>Bid</code>, <code>Moved</code>, <code>MatePaid</code>, <code>GameOver</code>, <code>DrawTriggered</code>, <code>EngineFailed</code>, <code>Withdrawn</code>, <code>ChestFunded</code>, <code>MainDuel</code>, <code>HookSwap</code>.</p>
<p><strong>Staking.</strong> The vault implements ERC-4626 in full, so any integration built for ERC-4626 works with it. Beyond the standard:</p>
<table>
<thead>
<tr>
<th>Function</th>
<th>Returns or does</th>
</tr>
</thead>
<tbody><tr>
<td><code>totalAssets()</code></td>
<td>the total staked: deposits plus rewards released so far, as of this block</td>
</tr>
<tr>
<td><code>reserve()</code></td>
<td>the reward reserve not yet released, as of this block</td>
</tr>
<tr>
<td><code>sync()</code></td>
<td>counts $IMDUEL sent to the vault into the reserve; opens the permanent stake on its first run (anyone)</td>
</tr>
<tr>
<td><code>maxDeposit(address)</code>, <code>maxMint(address)</code></td>
<td>0 until the permanent stake exists, then unlimited</td>
</tr>
</tbody></table>
<p>The fee router: <code>collect()</code> (anyone) claims the main duel&#39;s fees and forwards them; <code>admin()</code>, <code>pending()</code> and <code>readyAt()</code> show who can hand the requester on, to whom and from when (until <code>readyAt() + NOTICE</code>, then it expires); <code>NOTICE</code> is 3 days. Events: <code>Proposed(next, readyAt)</code>, <code>HandedOn(next)</code>, <code>Locked()</code>. Errors: <code>NotAdmin</code>, <code>NotReady</code> (no proposal, or its notice still running), <code>Expired</code> (propose again), <code>InvalidSetup</code> (also for a proposal naming the vault).</p>
<h2 id="security-and-risks"><a class="docs-anchor" href="#/docs/security-and-risks" aria-label="Link to this section">#</a>Security and risks</h2>
<p><strong>Audits and testing.</strong></p>
<ul>
<li>IMD swarm audits: <a href="https://explorer.imd.fun/jobs/74895075-9f30-49e2-8c89-ec79383f8102">74895075</a> on this code (1 low fixed, 1 info documented) and <a href="https://explorer.imd.fun/jobs/6acefe89-1311-462a-8f78-5697050c327d">6acefe89</a> on an earlier version (every finding fixed). The launch job audited the code again before deploying; its one change, the <code>NotEnoughGas</code> check, is in the deployed hook.</li>
<li>What the hook holds equals the reward pools plus the burn plus what is owed, in every currency, and every mate pays exactly the smallest of its three limits: checked by invariant tests, symbolic proofs and fuzzing with Foundry and Echidna.</li>
<li>The staking vault and the fee router: IMD swarm audit <a href="https://explorer.imd.fun/jobs/d944c9f4-820f-4a57-87f6-eca2032d2ede">d944c9f4</a> (2 low fixed, 4 info) and the swarm&#39;s review in job <a href="https://explorer.imd.fun/jobs/6141f96e-e23e-4cea-85f6-41c05f34602a">6141f96e</a> (the <code>propose()</code> low fixed), after four rounds of our own review, the last a red team with flash loans on a mainnet fork. They are covered by invariant tests and symbolic proofs with Halmos (every $IMDUEL the vault holds is staked or in the reserve; time, stakes and unstakes never lower the share value; the permanent stake never leaves), mutation testing and fork tests against the live IMD factory.</li>
<li>No owner, pause or upgrade: the hook, the engine and the staking vault are immutable. If the engine fails, a seeded legal move is played at 0% instead, and if that fails too the game ends in a draw, so a trade never breaks. A hostile token can only affect its own duel.</li>
</ul>
<p><strong>Known limits.</strong></p>
<ul>
<li><strong>Market risk.</strong> Token prices move, and a bid buys the token at market. Rewards aren&#39;t guaranteed.</li>
<li><strong>Block builders.</strong> Whoever builds a window&#39;s last block can bid in it and try versions of the block for a hash that plays a winning move. It only pays for a large prize, and a mate pays at most 2x what the bid paid.</li>
<li><strong>Reorganisations.</strong> A move is fixed once its window&#39;s last block is in. If the chain replaced that block (rare on Ethereum), the move would change with it.</li>
<li><strong>The last block.</strong> A raise in a window&#39;s last block can&#39;t be answered, and bots that see a mate in one will bid late for it.</li>
<li><strong>Small reward pools.</strong> While a pool is small every bid plays near the cap, and a large donation to a pool makes that team&#39;s bids weaker.</li>
<li><strong>Quiet duels.</strong> A move must be played within about a day (8,191 blocks) of its window closing, while its block hash is still on chain. After that it is drawn again, owned by nobody, at its bid&#39;s strength.</li>
<li><strong>Throwing games.</strong> A team can lose on purpose, but every move costs fees and the prize comes out of its own pool, so it loses money doing it.</li>
<li><strong>Relayed trades.</strong> A trade relayed for a smart-contract wallet without the owner in <code>hookData</code> credits the wallet that signed it.</li>
<li><strong>Staking rewards depend on fees.</strong> The reserve only refills while the main duel trades. Without new fees it keeps releasing 1% of what is left each day, so rewards shrink but never stop at once, and the share value never falls.</li>
<li><strong>Staking is not a hedge.</strong> A stake is counted in $IMDUEL; its dollar value moves with the $IMDUEL price.</li>
<li><strong>The fee router&#39;s admin.</strong> Until <code>lock()</code> is called, the admin can redirect the main duel&#39;s 1% to a new address, after a public 3-day notice. It has no power over the vault or anything staked.</li>
</ul>
`,markdown:`# IMDuel docs

<!-- group: Overview -->

## Introduction

IMDuel is a Uniswap v4 hook that plays chess. Every pool that uses it is a **duel**: its two tokens are two teams, and they play an endless series of chess games against each other.

- **Buying a token is a bid** for its team's next move. The biggest buy owns the move.
- **An onchain engine plays the move.** Nobody picks the square; a bigger buy makes the engine play stronger.
- **Checkmate wins the jackpot.** The owner of the mating move wins from the losing team's reward pool.

A bid is an ordinary buy: you keep the tokens you bought, and the move comes with it. There is no ticket, no deposit and no separate call.

The main duel is **$IMDUEL / $IMD** on Ethereum. Anyone can create a duel of another token against $IMD or $IMDUEL. The hook, the engine and the staking vault have no owner, no admin key, no pause and no upgrade.

$IMDUEL holders can also [stake](#/docs/staking) it for a share of the main duel's trading fees.

IMDuel is experimental. A bigger buy plays a stronger move but guarantees no mate, win or profit, and token prices move. Trade only what you can afford to lose.

## Quick start

1. **Get a token to pay with.** In the main duel you buy $IMDUEL with $IMD, or $IMD with $IMDUEL. $IMD trades on Uniswap against ETH. You also need ETH for gas.
2. **Connect.** Press Connect in the header and choose your wallet.
3. **Open a duel.** [Duels](#/duels) lists every duel; the main duel is first. Its page shows the board, whose move it is, the top bid and what a checkmate wins now.
4. **Buy for a team.** In the Trade panel, pick the team you back and an amount. The panel shows whether your buy takes the top bid and how strong the move would be.
5. **Watch the move.** About 36 seconds after the previous move, bidding closes and the move is fixed; the next trade in the pool plays it.

<!-- group: How it works -->

## How a game works

<div data-walkthrough></div>

### Teams

Each of a duel's two tokens is a team: buy $IMDUEL to play for $IMDUEL, buy $IMD to play for $IMD. You pay for one team's token with the other's, so every trade plays for exactly one team. The teams swap colours every game; in a duel's first game White is the duel's own token and Black the token it is paired against (in the main duel, $IMDUEL plays White).

### Bidding

Every buy of a team's token bids for that team's next move: the move being decided if it is that team's turn, otherwise its following move. There is no minimum, and any app or aggregator can send the trade.

- **The top bid owns the move.** Bids are compared by what the trade paid. To take the top spot, a buy must pay more than 10% over the current top bid; smaller buys just trade.
- **The owner** is the address the trade names. Trading on this site names you; a trade from another app names the wallet that signed it.
- **Bidding lasts 3 blocks** after the previous move is played, about 36 seconds on Ethereum. If a move's first bid comes in the last of those blocks or later, bidding stays open for 3 blocks from that bid, so the other bidders can always answer.
- **Bids carry over.** A bid for a move the game never reaches owns its team's first move of the next game.

### Playing the move

When bidding closes, the hash of the window's last block seeds the engine. That hash doesn't exist while anyone can still bid, so no bidder can know which move their bid will play. Once that block is mined the move is fixed, and the site shows it.

The first trade after that plays the move. It can come from either team and be any size; it doesn't change the move, but it pays the engine's gas (see [Gas](#/docs/gas)).

If the side to move gets no bid for 10 minutes, a trade by the other team opens that move at 0% strength, owned by nobody. A real bid in the same block takes it over. A move owned by nobody wins nothing, even if it mates.

### Game end

A game ends by checkmate or a draw. The board resets, the teams swap colours and the next trade starts a new game; the reward pools carry over. Draws are automatic:

- stalemate;
- too few pieces to mate (two kings, or a king and one knight or bishop against a king);
- the same position for the third time within the last sixteen half-moves (the start position counts from any distance);
- 60 half-moves without a capture or pawn move;
- 200 half-moves in total;
- the engine failing twice on one position (it never has).

## Strength

Strength is how hard the engine thinks about a move. It comes from the tokens the owning buy received, compared with its own team's reward pool, which is in the same token:

| Tokens received, as a share of the team's reward pool | Strength |
| --- | --- |
| 0.1% or less | 0% |
| 1% | 30% |
| 10% | 60% |
| The whole reward pool or more | 90% (the cap) |

Strength reads no price and no liquidity, so nothing outside the game can make a bid stronger or weaker. The one thing that changes it is the size of the reward pool: an empty pool plays at the cap, so right after launch and after a mate most moves play strong until the pool grows.

At 0% the engine plays like a beginner who still sees captures and checks; near the cap, like a strong amateur. Every strength keeps a few seeded mistakes, more at low strength, so games stay lively: even a whale's move can miss a mate.

The engine is a contract on Ethereum and runs inside the trade that plays the move. It scores every legal move for material, position, pressure on the enemy king and the risk it leaves, and always weighs captures and checks; higher strength gives the leading candidates more second looks. With a lone enemy king left it plays at full effort to finish the game, and the longer a game goes without a capture or pawn move, the harder it pushes for progress.

## Checkmate rewards

Checkmate wins the jackpot. The owner of the mating move wins from the **losing** team's reward pool, paid in the losing team's token: mate for $IMDUEL and you win $IMD; mate for $IMD and you win $IMDUEL. The winning team's own pool is untouched.

The prize is the smallest of three amounts:

1. a quarter of the losing team's reward pool;
2. 2x what the mating bid paid;
3. what this game's trades paid into the losing team's reward pool.

**Example.** $IMDUEL mates. The $IMD reward pool holds 10,000 $IMD, this game's trades paid 3,000 $IMD into it, and the mating bid paid 1,000 $IMD. The prize is the smallest of 2,500, 2,000 and 3,000: **2,000 $IMD**. The other 8,000 stay in the pool.

So every trade in the game grows the prize, and a bigger bid can win more. Only the mating move's owner is paid; captures, checks and draws leave the pools to grow until the next mate. A mate in one is visible to everyone, so expect a race for it: bots may bid in the window's last block, and their bids are buys like any other.

### Withdrawing

The prize is recorded for the owner when the mate is played; nothing is sent inside a trade. **Payouts**, under each duel's board, shows what is yours with a Withdraw button, and rewards wait as long as you like. Anyone can call \`withdraw\` for an owner, but it only ever pays that owner; \`withdrawTo\` lets the owner send to another address. A withdrawal leaves 1 wei behind, which makes the next reward cheaper to record; the site counts it as nothing.

## Fees and reward pools

Every swap in a duel pays two fees:

| Fee | Rate | Goes to |
| --- | --- | --- |
| Hook fee | 0.75% | 0.65% to the two reward pools, 0.1% burns $IMDUEL (see [Burn](#/docs/burn)) |
| Pool fee | 1.25% in the main duel | the pool's liquidity: 1% to the [fee router](#/docs/staking) ($IMDUEL to stakers, $IMD to the team), 0.25% to the IMD network |

A trade in the main duel costs 2% in fees, plus gas and price impact. Other duels charge the same hook fee and the pool fee their creator chose. Every swap emits Uniswap's standard \`HookSwap\` event with the hook fee, so explorers show the full cost.

**Reward pools.** Each duel has two, one per team, in that team's token.

- **Filled by every trade.** Half of the 0.65% is taken from what a trade pays, into that token's pool, and half from what it buys, into the other token's pool, so every trade feeds both pools by about the same value.
- **Emptied only by checkmate.** A mate's prize is the only thing that leaves a pool, and it never takes more than the game paid in, so a pool never ends a game smaller than it started.
- **Anyone can add to one** with the hook's \`fundChest\`. That raises what a mate against that team wins and makes that team's bids weaker, since strength is a share of the pool.

## $IMDUEL

$IMDUEL is IMDuel's token, launched on Ethereum by the IMD swarm together with the hook.

| | |
| --- | --- |
| Contract | \`0xc012b8Db13C57beCd950eEfB70540e6f973A3C73\` |
| Supply | 1,000,000,000, fixed: no minting, no tax, plain transfers |
| Pair | $IMDUEL / $IMD, the main duel |
| Opening price | 2,500 $IMD for the whole supply (1 $IMD = 400,000 $IMDUEL) |

$IMDUEL is a team in the main duel and in every duel paired against it, and the hook fee of every duel holding $IMDUEL burns it. Tokens named IMDuel at any other address are not $IMDUEL.

### Distribution

| Share | Goes to |
| --- | --- |
| 80% | The main duel's pool, single-sided: everyone buys from it |
| 8% | IMD seats connected at launch, shared equally (the swarm's airdrop) |
| 2% | Wallets that worked on the launch (the swarm's airdrop) |
| 10% | The launch wallet \`0x6AA3…5B23\`: the team, and seeding new features and chain expansions |

### Burn

0.1% of every swap is taken in $IMDUEL wherever a duel holds $IMDUEL, the main duel included, and burned. A duel paired with $IMD that holds no $IMDUEL takes its 0.1% in $IMD and adds it to the main duel's $IMD reward pool instead.

The burn is owed to \`0x…dEaD\` in the hook and sent there by anyone calling \`withdraw(0x…dEaD, IMDUEL)\`. The main duel's page shows the total burned.

## Staking

Stake $IMDUEL in the staking vault and receive **sIMDUEL**, a share of everything the vault holds. The vault pays stakers from a reward reserve, so each sIMDUEL is redeemable for more $IMDUEL over time. There is no lock-up, no fee and nothing to claim: rewards compound into the share value every second, and you can unstake at any time.

The vault is a standard [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) tokenized vault built on OpenZeppelin's implementation. sIMDUEL is an ERC-20 with 18 decimals and can be transferred like any other token; whoever holds it can redeem it.

### Shares

When you stake, the vault mints sIMDUEL at the current share value: staking 1,000 $IMDUEL while 1 sIMDUEL is worth 1.25 $IMDUEL mints 800 sIMDUEL. The number of shares you hold doesn't change after that; what grows is what each one is worth.

\`\`\`
share value = total staked / sIMDUEL supply
\`\`\`

**Total staked** is every $IMDUEL deposited plus every reward released so far. The share value only rises: rewards add to the total staked without minting shares, and staking or unstaking moves the total staked and the supply in proportion. As in every ERC-4626 vault, conversions round in the vault's favour, by at most 1 wei.

### The reward reserve

Rewards come from a separate balance in the vault, the **reward reserve**. The reserve is not part of the share value until it is released.

- **Released continuously.** The reserve releases 1% of itself a day, by the second, into the total staked. After \`t\` days with nothing new arriving it holds \`reserve × 0.99^t\`, so it halves in about 69 days. It only releases while someone besides the permanent stake is staked; until then it waits.
- **Refilled by fees.** Any $IMDUEL sent to the vault joins the reserve, not the stake. The main duel's trading fees arrive this way through the fee router, and future features can top it up the same way. \`sync()\` counts a transfer at once; otherwise it is counted at the next stake or unstake.
- **Never minted.** Rewards are only ever $IMDUEL that was sent to the vault. Staking creates no new supply.

The reserve started with 10,000,000 $IMDUEL from the launch wallet.

### APR

The staking page shows the current APR: what the reserve releases in a day, over a year, divided by the total staked.

\`\`\`
APR = reserve × 1% × 365 / total staked
\`\`\`

It is a snapshot, not a promise. It falls as more $IMDUEL is staked and as the reserve pays out, and rises when fees refill the reserve or stakers leave. Because rewards compound into the share value, a stake held for a year at a constant APR would earn slightly more than the APR.

### The permanent stake

The vault opens with 1 $IMDUEL staked on behalf of \`0x…dEaD\`, from the reserve, the first time \`sync()\` runs with at least 1 $IMDUEL in it. Those shares can never be redeemed. They keep sIMDUEL in existence at all times, so the vault is never empty, and no first depositor can inflate the share value against those who follow (the ERC-4626 inflation attack). Until the permanent stake exists, the vault accepts no deposits.

The permanent stake earns like any other, in proportion to its size, but only alongside other stakers: while it is the only stake, the reserve pays out nothing and waits for the first staker. Beside a very small stake it takes most of each payout, so the team's 1,000,000 $IMDUEL stays staked, which keeps its share at about a millionth. The staking page counts it as burned.

### The fee router

The main duel's pool fee is 1.25%. The IMD launch factory pays 1% of it to the launch's **requester** and 0.25% to the IMD network. The requester is the IMDuel fee router, which forwards what it receives:

| Token | Goes to |
| --- | --- |
| $IMDUEL | the staking vault's reward reserve |
| $IMD | the team |

Fees accrue in the factory until anyone calls the router's \`collect()\`, which claims them and forwards both tokens in the same transaction.

The router's admin can hand the requester role to a new address, for example a router with a different split. A handover must be proposed first and can only be carried out 3 days later, within the 3 days after that; a proposal left longer expires and has to be made again. So every change is public in advance through the \`Proposed\` event. The admin can also call \`lock()\`, which removes the admin for good and leaves the requester with this router permanently. The admin cannot move funds or touch the vault.

## Gas

| Trade | Typical gas |
| --- | --- |
| A trade that only bids | about 180,000 |
| A trade that plays a move | about 530,000; usually 350,000 to 650,000 |

The trade that plays a move runs the engine, so it costs more, whoever sends it. This site sends every trade with a gas limit of 5,000,000, and you pay only for the gas used.

Other apps estimate gas when you confirm, and bidding can close between that estimate and the block your trade lands in; then your trade is the one that plays the move. It must have the engine's full 3,000,000 gas on hand, or it reverts with \`NotEnoughGas\` instead of playing a weaker move: only the gas is spent, and it can be sent again with a higher limit. Integrations should send every trade with at least 5,000,000.

<!-- group: Guides -->

## Trading

The site trades through Uniswap's own contracts, the Universal Router and Permit2.

1. **Approve, once per token.** A transaction that lets Permit2 move that token.
2. **Sign a permit.** No gas. It lets the router spend this amount for a short time; skipped while an earlier permit still covers the trade.
3. **Send the trade.** One transaction, with the permit inside it.

**Slippage.** Auto allows 0.5% plus the largest recent price move within one block in this pool, at most 5%. Other bids for the same move buy the same token, so trades ahead of yours in a block move your price. Whatever you allow is also what a bot trading around yours could take.

**Liquidity.** The Pool switch on a duel's panel adds liquidity to its Uniswap pool. Liquidity earns the pool fee, shared by size; the hook fee goes to the game. Your position is a Uniswap position NFT in your wallet and has no effect on anyone's strength or rewards.

Wallets may show the value you receive as $0 until their price services list a new token; the token amount is what counts.

## Creating a duel

[Create a duel](#/create) for any ERC-20, or ETH, against $IMD or $IMDUEL. It's free apart from gas.

1. Pick the token, the pair and the pool fee.
2. Set the starting deposits: they set the opening price and become your liquidity position.
3. Confirm. If that exact pool already exists, the site opens it instead.

A new duel charges the hook fee from its first trade. It must be paired with $IMD or $IMDUEL, so its 0.1% always has somewhere to go; the hook refuses any other pair.

## Staking and unstaking

[Staking](#/staking) has one form for both directions.

1. **Stake.** Enter an amount of $IMDUEL, or press Max. The first stake asks for an approval of the vault, then the deposit; later stakes are a single transaction. The form shows the sIMDUEL you receive, your stake after and what it would earn a day at the current rate.
2. **Watch it grow.** Your stake is shown in $IMDUEL and updates every second. Nothing needs to be claimed.
3. **Unstake.** Switch to Unstake and enter an amount of sIMDUEL, or press Max to redeem every share. The $IMDUEL arrives in the same transaction.
4. **Fill the reserve.** The Reserve tab shows the main duel's fees waiting in the fee router. Anyone can send them on, for the gas alone: the $IMDUEL goes into the reserve for every staker.

The vault's standard ERC-4626 functions also stake for another address (\`deposit(assets, receiver)\`) and unstake to one (\`redeem(shares, receiver, owner)\`). Only the holder of sIMDUEL, or an address it approved, can redeem it.

## Profiles and leaderboard

Every address has a profile at \`#/profile/0x…\`: press an address anywhere on the site, or rest on it for a summary card. It shows what the hook counts for that address in the main duel (games, moves by piece, pieces taken, checks, castles, promotions, checkmates and amounts won) and the badges those counts earn. Names and avatars come from ENS.

The [Leaderboard](#/leaderboard) ranks every main-duel player by badges, checkmates, moves, pieces taken or games. Badges are computed from the hook's counts and are not minted. Only the main duel counts.

<!-- group: Reference -->

## Contracts

All on Ethereum mainnet.

| Contract | Address |
| --- | --- |
| IMDuelHook | [\`0xA92F72DcDd90229C32F6d51229F4cc5c916410CC\`](https://etherscan.io/address/0xA92F72DcDd90229C32F6d51229F4cc5c916410CC) |
| ChessEngineV5 | [\`0xc21788F704a8b9456f7391A01d8a3D95Be215a27\`](https://etherscan.io/address/0xc21788F704a8b9456f7391A01d8a3D95Be215a27) |
| $IMDUEL | [\`0xc012b8Db13C57beCd950eEfB70540e6f973A3C73\`](https://etherscan.io/address/0xc012b8Db13C57beCd950eEfB70540e6f973A3C73) |
| IMDuelStaking (sIMDUEL) | [\`0x8EA92158b116F835a4961baEFc7e1109562DD723\`](https://etherscan.io/address/0x8EA92158b116F835a4961baEFc7e1109562DD723) |
| IMDuelFeeRouter | [\`0xf4f9Daec44cC531Abe674184bBe8191024247E23\`](https://etherscan.io/address/0xf4f9Daec44cC531Abe674184bBe8191024247E23) |
| Main duel (pool id) | \`0xbb45eacf50b4bd8ce31e0620e14ff6e6b6375d56fce4372d3046f4a02faeae65\` |
| Launch wallet | \`0x6AA302EFf055259c9Cf177f33Ae3cBA5d4135B23\` |

Deployed through IMD launch 2843 ([job 4098dafa](https://explorer.imd.fun/jobs/4098dafa-99b4-4c9f-97e3-430b49ea6afa)) at block 26,322,077. The deployed source is in [the swarm's launch repository](https://github.com/identity-md-launches/launch-2843-launch-imduel-imduel-launch-json). The staking vault and the fee router were deployed by the launch wallet on 4 November 2026.

## Integrating

**Trading.** Any router or aggregator can trade a duel, and every buy bids. The owner of a bid is the address in \`hookData\`, 20 bytes packed or 32 bytes ABI-encoded; without it, the owner is the wallet that signed the transaction. Pass it for smart-contract wallets and relayed trades, where the signer isn't the trader. Gas limits: see [Gas](#/docs/gas).

\`\`\`
hookData = abi.encodePacked(owner)   // 20 bytes
hookData = abi.encode(owner)         // 32 bytes
\`\`\`

**Reading.** A duel is identified by its Uniswap pool id. Team 0 is \`currency0\`'s, team 1 \`currency1\`'s.

| Function | Returns |
| --- | --- |
| \`game(poolId)\` | the board, the side to move, both top bids, the bidding window and the last move |
| \`chest(poolId, team)\` | a team's reward pool |
| \`gameInflow(poolId, gameNo)\` | what a game's trades paid into each reward pool |
| \`previewMove(poolId, hash)\` | the move a closed window will play, given its last block's hash |
| \`owed(owner, currencyId)\` | rewards waiting to be withdrawn |
| \`stats(address)\` | a player's main-duel counts, in two packed words |
| \`players(i)\`, \`playerCount()\` | every address that has owned a played move in the main duel |
| \`MATE_SHARE_BPS\`, \`PAYOUT_CAP\`, \`MATE_INFLOW_CAP\` | the prize's three limits: 2,500 (a quarter), 2 (twice the bid), 1 (the game's pay-in) |

Events: \`GameStarted\`, \`Bid\`, \`Moved\`, \`MatePaid\`, \`GameOver\`, \`DrawTriggered\`, \`EngineFailed\`, \`Withdrawn\`, \`ChestFunded\`, \`MainDuel\`, \`HookSwap\`.

**Staking.** The vault implements ERC-4626 in full, so any integration built for ERC-4626 works with it. Beyond the standard:

| Function | Returns or does |
| --- | --- |
| \`totalAssets()\` | the total staked: deposits plus rewards released so far, as of this block |
| \`reserve()\` | the reward reserve not yet released, as of this block |
| \`sync()\` | counts $IMDUEL sent to the vault into the reserve; opens the permanent stake on its first run (anyone) |
| \`maxDeposit(address)\`, \`maxMint(address)\` | 0 until the permanent stake exists, then unlimited |

The fee router: \`collect()\` (anyone) claims the main duel's fees and forwards them; \`admin()\`, \`pending()\` and \`readyAt()\` show who can hand the requester on, to whom and from when (until \`readyAt() + NOTICE\`, then it expires); \`NOTICE\` is 3 days. Events: \`Proposed(next, readyAt)\`, \`HandedOn(next)\`, \`Locked()\`. Errors: \`NotAdmin\`, \`NotReady\` (no proposal, or its notice still running), \`Expired\` (propose again), \`InvalidSetup\` (also for a proposal naming the vault).

## Security and risks


**Audits and testing.**

- IMD swarm audits: [74895075](https://explorer.imd.fun/jobs/74895075-9f30-49e2-8c89-ec79383f8102) on this code (1 low fixed, 1 info documented) and [6acefe89](https://explorer.imd.fun/jobs/6acefe89-1311-462a-8f78-5697050c327d) on an earlier version (every finding fixed). The launch job audited the code again before deploying; its one change, the \`NotEnoughGas\` check, is in the deployed hook.
- What the hook holds equals the reward pools plus the burn plus what is owed, in every currency, and every mate pays exactly the smallest of its three limits: checked by invariant tests, symbolic proofs and fuzzing with Foundry and Echidna.
- The staking vault and the fee router: IMD swarm audit [d944c9f4](https://explorer.imd.fun/jobs/d944c9f4-820f-4a57-87f6-eca2032d2ede) (2 low fixed, 4 info) and the swarm's review in job [6141f96e](https://explorer.imd.fun/jobs/6141f96e-e23e-4cea-85f6-41c05f34602a) (the \`propose()\` low fixed), after four rounds of our own review, the last a red team with flash loans on a mainnet fork. They are covered by invariant tests and symbolic proofs with Halmos (every $IMDUEL the vault holds is staked or in the reserve; time, stakes and unstakes never lower the share value; the permanent stake never leaves), mutation testing and fork tests against the live IMD factory.
- No owner, pause or upgrade: the hook, the engine and the staking vault are immutable. If the engine fails, a seeded legal move is played at 0% instead, and if that fails too the game ends in a draw, so a trade never breaks. A hostile token can only affect its own duel.

**Known limits.**

- **Market risk.** Token prices move, and a bid buys the token at market. Rewards aren't guaranteed.
- **Block builders.** Whoever builds a window's last block can bid in it and try versions of the block for a hash that plays a winning move. It only pays for a large prize, and a mate pays at most 2x what the bid paid.
- **Reorganisations.** A move is fixed once its window's last block is in. If the chain replaced that block (rare on Ethereum), the move would change with it.
- **The last block.** A raise in a window's last block can't be answered, and bots that see a mate in one will bid late for it.
- **Small reward pools.** While a pool is small every bid plays near the cap, and a large donation to a pool makes that team's bids weaker.
- **Quiet duels.** A move must be played within about a day (8,191 blocks) of its window closing, while its block hash is still on chain. After that it is drawn again, owned by nobody, at its bid's strength.
- **Throwing games.** A team can lose on purpose, but every move costs fees and the prize comes out of its own pool, so it loses money doing it.
- **Relayed trades.** A trade relayed for a smart-contract wallet without the owner in \`hookData\` credits the wallet that signed it.
- **Staking rewards depend on fees.** The reserve only refills while the main duel trades. Without new fees it keeps releasing 1% of what is left each day, so rewards shrink but never stop at once, and the share value never falls.
- **Staking is not a hedge.** A stake is counted in $IMDUEL; its dollar value moves with the $IMDUEL price.
- **The fee router's admin.** Until \`lock()\` is called, the admin can redirect the main duel's 1% to a new address, after a public 3-day notice. It has no power over the vault or anything staked.
`,toc:[{group:`Overview`,sections:[{id:`introduction`,title:`Introduction`,sub:[]},{id:`quick-start`,title:`Quick start`,sub:[]}]},{group:`How it works`,sections:[{id:`how-a-game-works`,title:`How a game works`,sub:[{id:`teams`,title:`Teams`},{id:`bidding`,title:`Bidding`},{id:`playing-the-move`,title:`Playing the move`},{id:`game-end`,title:`Game end`}]},{id:`strength`,title:`Strength`,sub:[]},{id:`checkmate-rewards`,title:`Checkmate rewards`,sub:[{id:`withdrawing`,title:`Withdrawing`}]},{id:`fees-and-reward-pools`,title:`Fees and reward pools`,sub:[]},{id:`imduel`,title:`$IMDUEL`,sub:[{id:`distribution`,title:`Distribution`},{id:`burn`,title:`Burn`}]},{id:`staking`,title:`Staking`,sub:[{id:`shares`,title:`Shares`},{id:`the-reward-reserve`,title:`The reward reserve`},{id:`apr`,title:`APR`},{id:`the-permanent-stake`,title:`The permanent stake`},{id:`the-fee-router`,title:`The fee router`}]},{id:`gas`,title:`Gas`,sub:[]}]},{group:`Guides`,sections:[{id:`trading`,title:`Trading`,sub:[]},{id:`creating-a-duel`,title:`Creating a duel`,sub:[]},{id:`staking-and-unstaking`,title:`Staking and unstaking`,sub:[]},{id:`profiles-and-leaderboard`,title:`Profiles and leaderboard`,sub:[]}]},{group:`Reference`,sections:[{id:`contracts`,title:`Contracts`,sub:[]},{id:`integrating`,title:`Integrating`,sub:[]},{id:`security-and-risks`,title:`Security and risks`,sub:[]}]}]},v=(t,i)=>{let a=i.params.section;e(t,r`<div class="overview wrap">${s(`Docs`,{href:`#/`,label:`Home`},{lede:`How IMDuel works: the game, the money, the site and the contracts.`,end:n({label:`Find a duel`,href:`#/duels`,tone:`ink`,size:`sm`}),className:`overview-title`})}
    ${l(_,a)}</div>`);let o=t.querySelector(`[data-walkthrough]`);o&&e(o,h());let c=o?g(o.querySelector(`.walkthrough`)):void 0,d=u(t,_,a);return()=>{d(),c?.()}};export{v as default};