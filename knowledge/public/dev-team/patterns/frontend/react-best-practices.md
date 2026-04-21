# React Best Practices (Vercel)

Reference: https://github.com/vercel-labs/agent-skills/tree/main/skills/react-best-practices

## CRITICAL - Eliminating Waterfalls

### Defer Await Until Needed
```typescript
// BAD - blocks everything
async function Page() {
  const user = await getUser();
  const posts = await getPosts();
  return <div>...</div>;
}

// GOOD - parallel execution
async function Page() {
  const userPromise = getUser();
  const postsPromise = getPosts();
  const [user, posts] = await Promise.all([userPromise, postsPromise]);
  return <div>...</div>;
}
```

### Strategic Suspense Boundaries
```tsx
// Wrap independent data-fetching components
<Suspense fallback={<HeaderSkeleton />}>
  <Header />
</Suspense>
<Suspense fallback={<ContentSkeleton />}>
  <Content />
</Suspense>
```

## CRITICAL - Bundle Optimization

### Avoid Barrel File Imports
```typescript
// BAD - imports entire module
import { Button } from '@/components';

// GOOD - specific import
import { Button } from '@/components/ui/Button';
```

### Dynamic Imports for Heavy Components
```typescript
const HeavyChart = dynamic(() => import('@/components/Chart'), {
  loading: () => <ChartSkeleton />,
  ssr: false
});
```

## HIGH - Server Components

### React.cache() for Deduplication
```typescript
import { cache } from 'react';

export const getUser = cache(async (id: string) => {
  return db.user.findUnique({ where: { id } });
});
```

### Minimize RSC Serialization
```tsx
// BAD - serializes entire user object
<ClientComponent user={user} />

// GOOD - serialize only needed data
<ClientComponent userId={user.id} userName={user.name} />
```

### Use after() for Non-Blocking Work
```typescript
import { after } from 'next/server';

export async function POST(request: Request) {
  const data = await saveData();

  after(() => {
    // Non-blocking: analytics, cleanup, etc.
    sendAnalytics(data);
  });

  return Response.json(data);
}
```

## MEDIUM - Re-render Optimization

### Don't Wrap Simple Expressions
```typescript
// BAD - unnecessary overhead
const doubled = useMemo(() => count * 2, [count]);

// GOOD - just calculate it
const doubled = count * 2;
```

### Functional setState Updates
```typescript
// BAD - stale closure risk
setCount(count + 1);

// GOOD - always current
setCount(c => c + 1);
```

### Use Transitions for Non-Urgent Updates
```typescript
const [isPending, startTransition] = useTransition();

function handleFilter(value: string) {
  // Urgent: update input immediately
  setInputValue(value);

  // Non-urgent: can be interrupted
  startTransition(() => {
    setFilteredList(filterList(value));
  });
}
```

## MEDIUM - Rendering Performance

### CSS content-visibility for Long Lists
```css
.list-item {
  content-visibility: auto;
  contain-intrinsic-size: 0 50px;
}
```

### Prevent Hydration Mismatch
```typescript
const [mounted, setMounted] = useState(false);
useEffect(() => setMounted(true), []);

// Render placeholder on server, real content after hydration
if (!mounted) return <Skeleton />;
return <DynamicContent />;
```

## LOW-MEDIUM - JavaScript Performance

### Set/Map for O(1) Lookups
```typescript
// BAD - O(n) per check
const hasItem = items.includes(searchItem);

// GOOD - O(1) lookup
const itemSet = new Set(items);
const hasItem = itemSet.has(searchItem);
```

### Build Index Maps
```typescript
// BAD - repeated O(n) lookups
users.forEach(user => {
  const order = orders.find(o => o.userId === user.id);
});

// GOOD - O(1) after initial build
const ordersByUserId = new Map(orders.map(o => [o.userId, o]));
users.forEach(user => {
  const order = ordersByUserId.get(user.id);
});
```

## Key Principles

1. **Parallelize independent operations** - Never await sequentially
2. **Import specifically** - Avoid barrel files
3. **Serialize minimally** - Pass only needed data across RSC boundaries
4. **Defer non-critical work** - Use after(), Suspense, Transitions
5. **Measure first** - Don't optimize prematurely

## Learnings

- **CSS Modules pure selector rule**: NEVER use the universal `*` selector (or bare element selectors like `body`, `html`) in `.module.css` files — Turbopack throws `"Selector * is not pure (must contain at least one local class or id)"` at build time. To handle `prefers-reduced-motion` or other global concerns: implement a `useReducedMotion()` JS hook and apply transition suppression via inline styles, not CSS module rules. <!-- 2026-02-20 -->
