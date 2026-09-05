import { type CollectionEntry, getCollection } from "astro:content";

import { getCategoryUrl } from "@utils/url";
import { i18n } from "@i18n/translation";
import I18nKey from "@i18n/i18nKey";


// // Retrieve posts and sort them by publication date
async function getRawSortedPosts() {
    const allBlogPosts = await getCollection("posts", ({ data }) => {
        return import.meta.env.PROD ? data.draft !== true : true;
    });

    const sorted = allBlogPosts.sort((a, b) => {
        // 首先按置顶状态排序，置顶文章在前
        if (a.data.pinned && !b.data.pinned) return -1;
        if (!a.data.pinned && b.data.pinned) return 1;

        // 如果置顶状态相同，则按发布日期排序
        const dateA = new Date(a.data.published);
        const dateB = new Date(b.data.published);
        return dateA > dateB ? -1 : 1;
    });
    return sorted;
}

export async function getSortedPosts() {
    const sorted = await getRawSortedPosts();

    for (let i = 1; i < sorted.length; i++) {
        sorted[i].data.nextSlug = sorted[i - 1].id;
        sorted[i].data.nextTitle = sorted[i - 1].data.title;
    }
    for (let i = 0; i < sorted.length - 1; i++) {
        sorted[i].data.prevSlug = sorted[i + 1].id;
        sorted[i].data.prevTitle = sorted[i + 1].data.title;
    }

    return sorted;
}
export type PostForList = {
    id: string;
    data: CollectionEntry<"posts">["data"];
};
export async function getSortedPostsList(): Promise<PostForList[]> {
    const sortedFullPosts = await getRawSortedPosts();

    // delete post.body
    const sortedPostsList = sortedFullPosts.map((post) => ({
        id: post.id,
        data: post.data,
    }));

    return sortedPostsList;
}

export type SeriesGroup = {
    name: string;
    posts: CollectionEntry<"posts">[];
};

export async function getSeriesList(): Promise<SeriesGroup[]> {
    const posts = await getRawSortedPosts();
    const seriesMap = new Map<string, CollectionEntry<"posts">[]>();

    for (const post of posts) {
        const seriesName = post.data.series?.trim();
        if (!seriesName) continue;

        const seriesPosts = seriesMap.get(seriesName) || [];
        seriesPosts.push(post);
        seriesMap.set(seriesName, seriesPosts);
    }

    const groups = Array.from(seriesMap, ([name, seriesPosts]) => {
        seriesPosts.sort((a, b) => {
            const orderA = a.data.seriesOrder ?? Number.MAX_SAFE_INTEGER;
            const orderB = b.data.seriesOrder ?? Number.MAX_SAFE_INTEGER;
            if (orderA !== orderB) return orderA - orderB;

            return a.data.published.getTime() - b.data.published.getTime();
        });

        return { name, posts: seriesPosts };
    });

    return groups.sort((a, b) => {
        const latestA = Math.max(...a.posts.map(post => (post.data.updated || post.data.published).getTime()));
        const latestB = Math.max(...b.posts.map(post => (post.data.updated || post.data.published).getTime()));
        return latestB - latestA;
    });
}

export async function getSeriesByName(name: string): Promise<SeriesGroup | undefined> {
    const normalizedName = name.trim();
    const seriesList = await getSeriesList();
    return seriesList.find(series => series.name === normalizedName);
}
export type Tag = {
    name: string;
    count: number;
};

export async function getTagList(): Promise<Tag[]> {
    const allBlogPosts = await getCollection<"posts">("posts", ({ data }) => {
        return import.meta.env.PROD ? data.draft !== true : true;
    });

    const countMap: { [key: string]: number } = {};
    allBlogPosts.forEach((post: { data: { tags: string[] } }) => {
        post.data.tags.forEach((tag: string) => {
            if (!countMap[tag]) countMap[tag] = 0;
            countMap[tag]++;
        });
    });

    // sort tags
    const keys: string[] = Object.keys(countMap).sort((a, b) => {
        return a.toLowerCase().localeCompare(b.toLowerCase());
    });

    return keys.map((key) => ({ name: key, count: countMap[key] }));
}

export type Category = {
    name: string;
    count: number;
    url: string;
};

export async function getCategoryList(): Promise<Category[]> {
    const allBlogPosts = await getCollection<"posts">("posts", ({ data }) => {
        return import.meta.env.PROD ? data.draft !== true : true;
    });
    const count: { [key: string]: number } = {};
    allBlogPosts.forEach((post: { data: { category: string | null } }) => {
        if (!post.data.category) {
            const ucKey = i18n(I18nKey.uncategorized);
            count[ucKey] = count[ucKey] ? count[ucKey] + 1 : 1;
            return;
        }

        const categoryName =
            typeof post.data.category === "string"
                ? post.data.category.trim()
                : String(post.data.category).trim();

        count[categoryName] = count[categoryName] ? count[categoryName] + 1 : 1;
    });

    const lst = Object.keys(count).sort((a, b) => {
        return a.toLowerCase().localeCompare(b.toLowerCase());
    });

    const ret: Category[] = [];
    for (const c of lst) {
        ret.push({
            name: c,
            count: count[c],
            url: getCategoryUrl(c),
        });
    }
    return ret;
}
