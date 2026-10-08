Subject: Progress update: retail shop intelligence assignment

Dear Mr. Mostafizur Rahaman,

Thank you for the assignment. Here is where the work stands, what I can demonstrate, and what I need from Square Toiletries to go further.

**Summary**

I have built a working first version of a platform that connects outlets, products, orders and shelf photos, and turns them into recommendations for a Sales Officer. It runs end to end today on sample data that I generated myself. It does not yet contain any real Square data, and the image recognition is at an early stage. Both points are explained below.

**What works today**

1. *Our own product portfolio ratio.* For any outlet the system shows the mix of our brands it buys, compares it with the target for its channel and with similar outlets, and lists what is missing. Each finding states its evidence, for example: "This outlet bought 0 units of a product in 90 days, while 89% of 27 comparable outlets bought it."
2. *Competitor versus our products.* Competitor companies, brands and products are stored in the same catalogue as ours, so share of shelf and assortment can be compared by outlet, channel and territory once shelves are audited.
3. *Channel-wise product placement.* Placement expectations (shelf level, minimum facings, minimum share) are set per channel as editable rules, and each shelf audit is checked against them.
4. *Retail classification.* Outlets are classified by configurable rules, and every classification shows the reasons behind it. A manager can override it.
5. *Shelf photos.* A Sales Officer photographs a shelf in the mobile app, the system detects products, asks the officer to confirm anything it is unsure about, and then reports share of shelf and placement compliance. Photos taken without a connection are stored on the phone and sent later.
6. *Sales call support.* Before a visit the app prepares a short brief for the officer: what to offer, which promotion applies, what the outlet ordered last time, and a suggested order.

There are separate views for Sales Officers and for supervisors and managers.

**What is not ready, stated plainly**

- *All figures are sample data.* The outlets, sales and prices in the demonstration are generated and are labelled as such on every screen. They say nothing about the real market.
- *Image recognition is early.* The current model can only tell whether a pack carries the Square logo, and on my test photos it misses many products. It cannot yet name individual products or competitor brands. I measured this instead of assuming it. For now the officer's confirmation is what makes the shelf numbers reliable. Improving it needs real shelf photos and product images from Square.
- *AI voice.* The call brief described above is ready. Listening to a sales call and coaching on it is not built yet. I would like to confirm exactly what is expected before building it (see the questions below).

**Questions I need answered**

1. What does "3-dimensional picture format" mean for you: understanding where each product sits on the shelf from ordinary photos, or an actual 3D model of the shop? I have assumed the first.
2. Which product categories should come first?
3. For the AI voice part: should the AI help the officer prepare and practise before a visit, or listen to the real conversation with the shopkeeper? If calls are recorded, what are the rules on consent?
4. How do you currently define channels and outlet classes?

**Data that would let me replace the sample data**

- Product list with brand, category, pack size and prices
- Outlet list with location, channel and territory
- Six to twelve months of outlet-level sales by product
- Must-stock lists and shelf placement guidelines by channel
- Pack images of our products, and a list of the main competitor products
- Current promotions

I would be glad to demonstrate the working system at a time that suits you.

Best regards,
Tanjim Mahmud Rakin
