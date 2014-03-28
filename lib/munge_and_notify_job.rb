MungeAndNotifyJob = Struct.new(:earl_id, :type, :email, :photocracy, :redis_key)
class MungeAndNotifyJob

  def on_permanent_failure
    IdeaMailer.deliver_export_failed([APP_CONFIG[:ERRORS_EMAIL], email], photocracy)
  end

  # munges CSV file generated by pairwise to augment or remove the CSV
  # also notifies the user that their file is ready
  def perform
    SiteConfig.set_pairwise_credentials(photocracy)
    earl = Earl.find(earl_id)

    # delayed job doesn't like passing the user as parameter
    # so we do this manually
    current_user = User.find_by_email(email)

    r = Redis.new(:host => REDIS_CONFIG['hostname'])

    thekey, zlibcsv = r.blpop(redis_key, (60*10).to_s) # Timeout - 10 minutes

    r.del(redis_key) # client is responsible for deleting key

    zstream = Zlib::Inflate.new
    csvdata = zstream.inflate(zlibcsv).force_encoding('UTF-8')
    zstream.finish
    zstream.close

    # for creating zlibed CSV at the end
    zoutput = Zlib::Deflate.new
    znewcsv = ''

    #Caching these to prevent repeated lookups for the same session, Hackish, but should be fine for background job
    sessions = {}
    url_aliases = {}

    num_slugs = earl.slugs.size

    modified_csv = CSVBridge.generate do |csv|
      CSVBridge.parse(csvdata, {:headers => :first_row, :return_headers => true}) do |row|

        if row.header_row?
          if photocracy
            if type == 'votes'
              row << ['Winner Photo Name', 'Winner Photo Name']
              row << ['Loser Photo Name', 'Loser Photo Name']
            elsif type == 'non_votes'
              row << ['Left Photo Name', 'Left Photo Name']
              row << ['Right Photo Name', 'Right Photo Name']
            elsif type == 'ideas'
              row << ['Photo Name', 'Photo Name']
            end
          end

          case type
            when "votes", "non_votes"
              #We need this to look up SessionInfos, but the user doesn't need to see it
              row.delete('Session Identifier')

              row << ['Hashed IP Address', 'Hashed IP Address']
              row << ['URL Alias', 'URL Alias']
              row << ['User Agent', 'User Agent']
              row << ['Referrer', 'Referrer']
              row << ['Widget', 'Widget']
              row << ['Info', 'Info']
              if current_user.admin?
                #row << ['Geolocation Info', 'Geolocation Info']
              end
            when "ideas"
              row.delete('Session Identifier')
              row << ['Info', 'Info']
          end
          csv << row
          # Zlib the CSV as we create it
          znewcsv << zoutput.deflate(row.to_csv, Zlib::SYNC_FLUSH)
        else
          if photocracy
            if    type == 'votes'
              p1 = Photo.find_by_id(row['Winner Text'])
              p2 = Photo.find_by_id(row['Loser Text'])
              row << [ 'Winner Photo Name', p1 ? p1.photo_name : 'NA' ]
              row << [ 'Loser Photo Name',  p2 ? p2.photo_name : 'NA' ]
            elsif type == 'non_votes'
              p1 = Photo.find_by_id(row['Left Choice Text'])
              p2 = Photo.find_by_id(row['Right Choice Text'])
              row << [ 'Left Photo Name',  p1 ? p1.photo_name : 'NA' ]
              row << [ 'Right Photo Name', p2 ? p2.photo_name : 'NA' ]
            elsif type == 'ideas'
              p1 = Photo.find_by_id(row['Idea Text'])
              row << [ 'Photo Name', p1 ? p1.photo_name : 'NA' ]
            end
          end

          case type
            when 'ideas'
              sid = row['Session Identifier']
              row.delete('Session Identifier')
              user_session = sessions[sid]
              if user_session.nil?
                user_session = SessionInfo.find_by_session_id(sid)
                sessions[sid] = user_session
              end
              unless user_session.nil?
                info = user_session.find_info_value(row)
                info = 'NA' unless info 
                row << ['Info', info]
              end
            when "votes", "non_votes"

              sid = row['Session Identifier']
              row.delete('Session Identifier')

              user_session = sessions[sid]
              if user_session.nil?
                user_session = SessionInfo.find_by_session_id(sid)
                sessions[sid] = user_session
              end

              unless user_session.nil? #edge case, all appearances and votes after april 8 should have session info
                # Some marketplaces can be accessed via more than one url
                if num_slugs > 1
                  url_alias = url_aliases[sid]

                  if url_alias.nil?
                    max = 0
                    earl.slugs.each do |slug|
                      num = user_session.clicks.count(:conditions => ['url like ?', '%' + slug.name + '%' ])

                      if num > max
                        url_alias = slug.name
                        max = num
                      end
                    end

                    url_aliases[sid] = url_alias
                  end
                else
                  url_alias = earl.name
                end

                


                row << ['Hashed IP Address', Digest::MD5.hexdigest([user_session.ip_addr, APP_CONFIG[:IP_ADDR_HASH_SALT]].join(""))]
                row << ['URL Alias', url_alias]
                row << ['User Agent', user_session.user_agent]

                # grab most recent referrer from clicks
                # that is older than this current vote
                # and belongs to this earl
                slugs = earl.slugs
                slugw = slugs.map {|s| "url like ?"}.join(" OR ")
                slugv = slugs.map {|s| "%/#{s.name}%"}
                conditions = ["controller = 'earls' AND action = 'show' AND created_at < ? AND (#{slugw})", row['Created at']]
                conditions += slugv
                session_start = user_session.clicks.find(:first, :conditions => conditions, :order => 'created_at DESC')
                referrer = (session_start) ? session_start.referrer : 'REFERRER_NOT_FOUND'
                referrer = 'DIRECT_VISIT' if referrer == '/'
                # we've had some referrers be UTF-8, rest of CSV is ASCII-8BIT
                row << ['Referrer', referrer]

                vote_click = user_session.find_click_for_vote(row)
                widget = (vote_click.widget?) ? 'TRUE' : 'FALSE'
                row << ['Widget', widget]

                info = user_session.find_info_value(row)
                info = 'NA' unless info 
                row << ['Info', info]

                if current_user.admin?
                  #row << ['Geolocation Info', user_session.loc_info.to_s]
                end
              end
            end
            # Zlib the CSV as we create it
            znewcsv << zoutput.deflate(row.to_csv, Zlib::SYNC_FLUSH)
        end
      end
    end
    znewcsv << zoutput.finish
    zoutput.close

    export_id = Export.connection.insert("INSERT INTO `exports` (`name`, `data`, `compressed`) VALUES (#{Export.connection.quote(redis_key)}, #{Export.connection.quote(znewcsv)}, 1)")
    Delayed::Job.enqueue DestroyOldExportJob.new(export_id), 20, 3.days.from_now
    url = "/export/#{redis_key}"
    IdeaMailer.deliver_export_data_ready(email, url, photocracy)

    return true
  end
end
