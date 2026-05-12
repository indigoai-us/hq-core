/**
 * A/B Copy Variants Generator (US-013)
 * Generates alternative copy options for testing and optimization
 */

// ============================================
// Types
// ============================================

export type VariantApproach = 'emotional' | 'logical' | 'urgent' | 'social-proof' | 'benefit-focused';

export interface CopyVariant {
  id: string;
  approach: VariantApproach;
  text: string;
  rationale: string;
}

export interface VariantContext {
  pageSlug: string;
  sectionId?: string;
  sectionType?: string;
  targetAudience?: string;
  productName?: string;
  keyBenefit?: string;
}

export interface VariantSet {
  original: string;
  sectionId?: string;
  pageSlug: string;
  variants: CopyVariant[];
}

// ============================================
// Variant ID Generation
// ============================================

let variantCounter = 0;

function generateVariantId(approach: VariantApproach): string {
  variantCounter++;
  return `var-${approach}-${Date.now()}-${variantCounter}`;
}

// ============================================
// Main Variant Generation
// ============================================

/**
 * Generate A/B copy variants for a text
 */
export function generateVariants(text: string, context: VariantContext): VariantSet {
  const variants: CopyVariant[] = [];

  // Generate variants for each approach
  const emotional = generateEmotionalVariant(text, context);
  const logical = generateLogicalVariant(text, context);
  const urgent = generateUrgentVariant(text, context);
  const socialProof = generateSocialProofVariant(text, context);
  const benefitFocused = generateBenefitFocusedVariant(text, context);

  // Only include variants that are meaningfully different from original
  if (emotional.text !== text) variants.push(emotional);
  if (logical.text !== text) variants.push(logical);
  if (urgent.text !== text) variants.push(urgent);
  if (socialProof.text !== text) variants.push(socialProof);
  if (benefitFocused.text !== text) variants.push(benefitFocused);

  return {
    original: text,
    sectionId: context.sectionId,
    pageSlug: context.pageSlug,
    variants,
  };
}

/**
 * Generate variants for a specific approach only
 */
export function generateVariantForApproach(
  text: string,
  approach: VariantApproach,
  context: VariantContext
): CopyVariant {
  switch (approach) {
    case 'emotional':
      return generateEmotionalVariant(text, context);
    case 'logical':
      return generateLogicalVariant(text, context);
    case 'urgent':
      return generateUrgentVariant(text, context);
    case 'social-proof':
      return generateSocialProofVariant(text, context);
    case 'benefit-focused':
      return generateBenefitFocusedVariant(text, context);
  }
}

// ============================================
// Specific Variant Generators
// ============================================

/**
 * Generate emotional variant
 * Focuses on feelings, aspirations, and connection
 */
export function generateEmotionalVariant(text: string, context?: VariantContext): CopyVariant {
  let variant = text;

  // Transform technical/neutral language to emotional
  const emotionalTransforms: [RegExp, string][] = [
    // Product descriptors
    [/provides secure/gi, 'gives you peace of mind with'],
    [/offers? (?:the )?solution/gi, 'transforms how you'],
    [/enables you to/gi, 'empowers you to'],
    [/allows you to/gi, 'frees you to'],
    [/helps you/gi, 'supports you in'],

    // Feature language
    [/\bplatform\b/gi, 'partner'],
    [/\btool\b/gi, 'ally'],
    [/\bsoftware\b/gi, 'solution you can trust'],

    // Outcome language
    [/increase (?:your )?efficiency/gi, 'reclaim your time'],
    [/reduce costs/gi, 'invest in what matters'],
    [/improve productivity/gi, 'achieve more of what you love'],

    // Generic CTA transforms
    [/^learn more$/i, 'Discover Your Potential'],
    [/^get started$/i, 'Begin Your Journey'],
    [/^contact us$/i, 'Let\'s Connect'],
    [/^sign up$/i, 'Join Our Community'],
  ];

  for (const [pattern, replacement] of emotionalTransforms) {
    variant = variant.replace(pattern, replacement);
  }

  // Add emotional opener if short text
  if (text.length < 100 && variant === text) {
    const emotionalOpeners = [
      'Finally, ',
      'Imagine ',
      'Experience ',
      'Discover ',
    ];
    const opener = emotionalOpeners[Math.floor(text.length % emotionalOpeners.length)];
    variant = opener + text.charAt(0).toLowerCase() + text.slice(1);
  }

  return {
    id: generateVariantId('emotional'),
    approach: 'emotional',
    text: variant,
    rationale: 'Emotional variant focuses on feelings, aspirations, and personal connection to drive engagement.',
  };
}

/**
 * Generate logical variant
 * Focuses on facts, data, and rational arguments
 */
export function generateLogicalVariant(text: string, context?: VariantContext): CopyVariant {
  let variant = text;

  // Transform emotional/vague language to logical
  const logicalTransforms: [RegExp, string][] = [
    // Vague claims to specific
    [/\bsave time\b/gi, 'reduce processing time by up to 40%'],
    [/\bboost productivity\b/gi, 'increase output by an average of 25%'],
    [/\bimprove efficiency\b/gi, 'streamline workflows with measurable results'],
    [/\breduce errors\b/gi, 'achieve 99.9% accuracy rates'],

    // Emotional to factual
    [/\bamazing\b/gi, 'proven'],
    [/\bincredible\b/gi, 'significant'],
    [/\bpowerful\b/gi, 'comprehensive'],
    [/\bseamless\b/gi, 'integrated'],
    [/\bworld-class\b/gi, 'enterprise-grade'],

    // Add specificity
    [/\bmany companies\b/gi, 'over 500 companies'],
    [/\bthousands of\b/gi, '10,000+'],
    [/\bleading\b/gi, 'top-ranked'],

    // CTA transforms
    [/^learn more$/i, 'See the Data'],
    [/^get started$/i, 'Start Your Free Trial'],
    [/^contact us$/i, 'Request a Technical Demo'],
  ];

  for (const [pattern, replacement] of logicalTransforms) {
    variant = variant.replace(pattern, replacement);
  }

  // Add logical framing if unchanged
  if (variant === text && text.length < 150) {
    const logicalFrames = [
      'The data shows: ',
      'Research confirms: ',
      'Based on our analysis, ',
      'Studies demonstrate that ',
    ];
    const frame = logicalFrames[Math.floor(text.length % logicalFrames.length)];
    variant = frame + text.charAt(0).toLowerCase() + text.slice(1);
  }

  return {
    id: generateVariantId('logical'),
    approach: 'logical',
    text: variant,
    rationale: 'Logical variant emphasizes facts, data, and rational arguments for analytical decision-makers.',
  };
}

/**
 * Generate urgent variant
 * Creates sense of scarcity and time pressure
 */
export function generateUrgentVariant(text: string, context?: VariantContext): CopyVariant {
  let variant = text;

  // Add urgency to CTAs and statements
  const urgentTransforms: [RegExp, string][] = [
    // CTA urgency
    [/^learn more$/i, 'Get Access Now'],
    [/^get started$/i, 'Start Today - Limited Spots'],
    [/^contact us$/i, 'Schedule Your Demo Today'],
    [/^sign up$/i, 'Claim Your Spot Now'],
    [/^try it free$/i, 'Start Your Free Trial Now'],
    [/^request demo$/i, 'Book Your Demo - Slots Filling Fast'],

    // Statement urgency
    [/you can/gi, 'you can now'],
    [/we offer/gi, 'for a limited time, we offer'],
    [/available/gi, 'available now'],

    // Outcome urgency
    [/\bstart saving\b/gi, 'start saving immediately'],
    [/\bget results\b/gi, 'get results within days'],
    [/\bsee improvements\b/gi, 'see improvements this week'],
  ];

  for (const [pattern, replacement] of urgentTransforms) {
    variant = variant.replace(pattern, replacement);
  }

  // Add urgency suffix if unchanged
  if (variant === text) {
    const urgentSuffixes = [
      ' - Act Now',
      ' - Limited Time Offer',
      ' - Don\'t Wait',
      ' - Start Today',
    ];
    // Only add to short texts (CTAs)
    if (text.length < 50) {
      const suffix = urgentSuffixes[Math.floor(text.length % urgentSuffixes.length)];
      variant = text + suffix;
    }
  }

  return {
    id: generateVariantId('urgent'),
    approach: 'urgent',
    text: variant,
    rationale: 'Urgent variant creates scarcity and time pressure to drive immediate action.',
  };
}

/**
 * Generate social proof variant
 * Leverages credibility, testimonials, and peer validation
 */
export function generateSocialProofVariant(text: string, context?: VariantContext): CopyVariant {
  let variant = text;

  // Add social proof elements
  const socialProofTransforms: [RegExp, string][] = [
    // Trust signals
    [/\bsecure\b/gi, 'trusted by 1000+ companies'],
    [/\breliable\b/gi, 'relied upon by industry leaders'],
    [/\bproven\b/gi, 'proven by customer success stories'],

    // CTA social proof
    [/^learn more$/i, 'See Why Teams Choose Us'],
    [/^get started$/i, 'Join 10,000+ Happy Customers'],
    [/^contact us$/i, 'Talk to Our Award-Winning Team'],
    [/^sign up$/i, 'Join Industry Leaders'],
    [/^try it free$/i, 'See What Everyone\'s Talking About'],

    // Outcome validation
    [/\bimprove\b/gi, 'improve (like our 500+ customers have)'],
    [/\bachieve\b/gi, 'achieve (as verified by our users)'],
  ];

  for (const [pattern, replacement] of socialProofTransforms) {
    variant = variant.replace(pattern, replacement);
  }

  // Add social proof framing if unchanged
  if (variant === text && text.length < 200) {
    const socialFrames = [
      'Trusted by industry leaders: ',
      'What our customers already know: ',
      'Join thousands who have discovered: ',
      'As our customers will tell you: ',
    ];
    const frame = socialFrames[Math.floor(text.length % socialFrames.length)];
    variant = frame + text.charAt(0).toLowerCase() + text.slice(1);
  }

  return {
    id: generateVariantId('social-proof'),
    approach: 'social-proof',
    text: variant,
    rationale: 'Social proof variant leverages credibility and peer validation to build trust.',
  };
}

/**
 * Generate benefit-focused variant
 * Emphasizes outcomes and value to the user
 */
export function generateBenefitFocusedVariant(text: string, context?: VariantContext): CopyVariant {
  let variant = text;

  // Transform features to benefits
  const benefitTransforms: [RegExp, string][] = [
    // Feature to benefit
    [/\bautomation\b/gi, 'hours saved every week'],
    [/\bintegration\b/gi, 'all your tools working together'],
    [/\banalytics\b/gi, 'insights that drive growth'],
    [/\breporting\b/gi, 'clarity on what matters'],
    [/\bsecurity\b/gi, 'protection for what matters most'],
    [/\bcompliance\b/gi, 'worry-free operations'],

    // Process to outcome
    [/we (?:will )?process/gi, 'you\'ll get'],
    [/we (?:will )?handle/gi, 'you\'ll enjoy'],
    [/we (?:will )?manage/gi, 'you\'ll control'],

    // Technical to benefit
    [/\bAI-powered\b/gi, 'smarter'],
    [/\bcloud-based\b/gi, 'accessible anywhere'],
    [/\breal-time\b/gi, 'instant'],
    [/\bscalable\b/gi, 'grows with you'],

    // CTA benefits
    [/^learn more$/i, 'See What You\'ll Gain'],
    [/^get started$/i, 'Start Seeing Results'],
    [/^contact us$/i, 'Discover Your Benefits'],
    [/^sign up$/i, 'Unlock Your Potential'],
  ];

  for (const [pattern, replacement] of benefitTransforms) {
    variant = variant.replace(pattern, replacement);
  }

  // Add benefit framing if unchanged
  if (variant === text && text.length < 150) {
    // Try to identify the implied benefit and make it explicit
    const keyBenefit = context?.keyBenefit ?? 'results';
    variant = `Get the ${keyBenefit} you need: ${text.charAt(0).toLowerCase()}${text.slice(1)}`;
  }

  return {
    id: generateVariantId('benefit-focused'),
    approach: 'benefit-focused',
    text: variant,
    rationale: 'Benefit-focused variant emphasizes outcomes and value to the user, not features.',
  };
}

// ============================================
// CTA-Specific Variants
// ============================================

/**
 * Generate variants specifically for CTA buttons
 */
export function generateCTAVariants(ctaText: string, context: VariantContext): VariantSet {
  const variants: CopyVariant[] = [];

  // Action-oriented
  variants.push({
    id: generateVariantId('benefit-focused'),
    approach: 'benefit-focused',
    text: transformCTAToAction(ctaText),
    rationale: 'Action-oriented CTA that clearly states what the user will do.',
  });

  // Value-oriented
  variants.push({
    id: generateVariantId('benefit-focused'),
    approach: 'benefit-focused',
    text: transformCTAToValue(ctaText, context),
    rationale: 'Value-oriented CTA that emphasizes what the user will gain.',
  });

  // Urgency-oriented
  variants.push({
    id: generateVariantId('urgent'),
    approach: 'urgent',
    text: transformCTAToUrgent(ctaText),
    rationale: 'Urgency-oriented CTA that creates time pressure.',
  });

  // Social-oriented
  variants.push({
    id: generateVariantId('social-proof'),
    approach: 'social-proof',
    text: transformCTAToSocial(ctaText),
    rationale: 'Social-oriented CTA that leverages peer validation.',
  });

  // Filter duplicates and variants identical to original
  const uniqueVariants = variants.filter((v, i, arr) =>
    v.text !== ctaText && arr.findIndex(x => x.text === v.text) === i
  );

  return {
    original: ctaText,
    sectionId: context.sectionId,
    pageSlug: context.pageSlug,
    variants: uniqueVariants,
  };
}

function transformCTAToAction(cta: string): string {
  const actionMap: Record<string, string> = {
    'learn more': 'Explore Features',
    'get started': 'Create Account',
    'contact us': 'Send Message',
    'sign up': 'Create Free Account',
    'subscribe': 'Join Newsletter',
    'download': 'Get Your Copy',
    'try free': 'Start Free Trial',
    'request demo': 'Schedule Demo',
    'buy now': 'Complete Purchase',
    'add to cart': 'Add to Cart',
  };

  const lower = cta.toLowerCase().trim();
  return actionMap[lower] ?? cta;
}

function transformCTAToValue(cta: string, context: VariantContext): string {
  const valueMap: Record<string, string> = {
    'learn more': 'See How It Works',
    'get started': 'Start Saving Time',
    'contact us': 'Get Expert Help',
    'sign up': 'Unlock All Features',
    'subscribe': 'Get Exclusive Updates',
    'download': 'Get Your Free Guide',
    'try free': 'Try Risk-Free',
    'request demo': 'See It In Action',
    'buy now': 'Get Instant Access',
  };

  const lower = cta.toLowerCase().trim();
  return valueMap[lower] ?? cta;
}

function transformCTAToUrgent(cta: string): string {
  const urgentMap: Record<string, string> = {
    'learn more': 'Discover Now',
    'get started': 'Start Now',
    'contact us': 'Talk to Us Today',
    'sign up': 'Sign Up Now',
    'subscribe': 'Subscribe Today',
    'download': 'Download Now',
    'try free': 'Try Free Today',
    'request demo': 'Book Demo Now',
    'buy now': 'Buy Now - Limited Offer',
  };

  const lower = cta.toLowerCase().trim();
  return urgentMap[lower] ?? `${cta} Now`;
}

function transformCTAToSocial(cta: string): string {
  const socialMap: Record<string, string> = {
    'learn more': 'See Why Teams Love Us',
    'get started': 'Join 10,000+ Users',
    'contact us': 'Talk to Our Team',
    'sign up': 'Join the Community',
    'subscribe': 'Join 50,000+ Subscribers',
    'download': 'Get the Popular Guide',
    'try free': 'See What Others Discovered',
    'request demo': 'See the Award-Winner',
  };

  const lower = cta.toLowerCase().trim();
  return socialMap[lower] ?? cta;
}

// ============================================
// Formatting
// ============================================

/**
 * Format variants for easy comparison
 */
export function formatVariantComparison(variantSet: VariantSet): string {
  const lines: string[] = [
    `## Copy Variants for: ${variantSet.pageSlug}${variantSet.sectionId ? ` (${variantSet.sectionId})` : ''}`,
    '',
    '### Original',
    `> ${variantSet.original}`,
    '',
    '### Variants',
  ];

  for (const variant of variantSet.variants) {
    lines.push('');
    lines.push(`**${formatApproach(variant.approach)}**`);
    lines.push(`> ${variant.text}`);
    lines.push(`_${variant.rationale}_`);
  }

  return lines.join('\n');
}

function formatApproach(approach: VariantApproach): string {
  const labels: Record<VariantApproach, string> = {
    'emotional': 'Emotional Appeal',
    'logical': 'Logical/Data-Driven',
    'urgent': 'Urgency',
    'social-proof': 'Social Proof',
    'benefit-focused': 'Benefit-Focused',
  };
  return labels[approach];
}

/**
 * Format multiple variant sets as markdown
 */
export function formatAllVariantsMarkdown(variantSets: VariantSet[]): string {
  const sections = variantSets.map(vs => formatVariantComparison(vs));
  return ['# A/B Copy Variants\n', ...sections].join('\n---\n');
}

/**
 * Format variants as a comparison table
 */
export function formatVariantTable(variantSet: VariantSet): string {
  const lines: string[] = [
    '| Approach | Copy | Rationale |',
    '|----------|------|-----------|',
    `| Original | ${variantSet.original} | Current version |`,
  ];

  for (const variant of variantSet.variants) {
    const approach = formatApproach(variant.approach);
    lines.push(`| ${approach} | ${variant.text} | ${variant.rationale} |`);
  }

  return lines.join('\n');
}

// ============================================
// Batch Processing
// ============================================

/**
 * Generate variants for multiple texts
 */
export function generateVariantsForTexts(
  texts: Array<{ text: string; context: VariantContext }>
): VariantSet[] {
  return texts.map(({ text, context }) => generateVariants(text, context));
}

/**
 * Get all unique variant texts from a set
 */
export function getAllVariantTexts(variantSet: VariantSet): string[] {
  return [variantSet.original, ...variantSet.variants.map(v => v.text)];
}

/**
 * Filter variants by approach
 */
export function filterVariantsByApproach(
  variantSets: VariantSet[],
  approaches: VariantApproach[]
): VariantSet[] {
  return variantSets.map(vs => ({
    ...vs,
    variants: vs.variants.filter(v => approaches.includes(v.approach)),
  }));
}
