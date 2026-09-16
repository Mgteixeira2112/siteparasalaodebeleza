import { createClient } from '@supabase/supabase-js'

const supabaseUrl = 'https://mbsnmmhhvorkwmgzrnvi.supabase.co'
const supabasePublishableKey = 'sb_publishable_vITBfUrWwr8qw7BDaN5zEA_TJrQdKkT'

export const supabase = createClient(supabaseUrl, supabasePublishableKey)
