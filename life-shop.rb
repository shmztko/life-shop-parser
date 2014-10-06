# coding: utf-8
require 'csv'
require 'mechanize'
require 'erb'
require 'yaml'
require 'logger'

LOGGER = Logger.new('life-shop-parser.log')
LOGGER.progname = 'life-shop-parser'
LOGGER.level = Logger::INFO

# &nbsp;置換用定数
NBSP = Nokogiri::HTML("&nbsp;").text

# ライフWebページ情報
AREA_CODES = {kanto:'03', kinki:'06'}

SHOP_LIST_PAGE_URL = 'http://www.lifecorp.jp/CGI/store/shop.cgi?area_cd='
SHOP_DETAIL_PAGE_URL = 'http://www.lifecorp.jp/CGI/store/shop.cgi?mode=detail&area_cd=@area_code@&shop_cd=@shop_code@'

# 外部API
GEOCODING_API_URL = 'http://www.geocoding.jp/api/?q=@address@'

def save_shop_list(mechanize_agent)
    result = []
    AREA_CODES.each_value{|value|
      load_shop_list(mechanize_agent, value, result)
    }

    headers = result.first.keys

    CSV.open(CONFIG['result.file.path'], 'wb') {|csv|
      csv << headers
      result.each {|elem| csv << elem.values}
    }  
end

def load_shop_list(mechanize_agent, area_code, result = []) 
  LOGGER.info "Fetching shop list from area code (#{area_code})"
  shop_page = mechanize_agent.get("#{SHOP_LIST_PAGE_URL}#{area_code}")

  prev_area = ''
  shop_page.search('table.table03 > tr').each{|shop|
    if shop['class'].nil?
      shop_rows = shop.children.select{|s|s.element?}
      if shop_rows.size >= 4
        result_row = {}
        # 店舗エリア
        shop_area = shop_rows[0].text.gsub(NBSP, '')
        shop_area = shop_area.empty? ? prev_area : shop_area
        prev_area = shop_area
        result_row["area"] = shop_area
        result_row["area_code"]

        # 店舗コード、店舗名
        shop_link = shop_rows[1]>('a')
        shop_code = shop_link.attr('href').value.scan(/^.+shop_cd=([0-9]+)$/)[0][0]
        result_row["code"] = shop_code
        result_row["name"] = shop_link.text

        # 店舗詳細ページから詳しい情報を取得
        LOGGER.info "Fetching details of shop code (#{shop_code})."
        load_shop_detail(mechanize_agent, area_code, shop_code, result_row)

        # 詳細ページを見なくても、電話番号と住所は以下のコードで取得可能
        # shop_phone = shop_rows[2].text.strip
        # shop_address = shop_rows[3].text.strip.gsub(/\s+/, ' ')

        result << result_row
       end
    end
  }
  result
end

def load_shop_detail(mechanize_agent, area_code, shop_code, result={})
  shop_detail_page = mechanize_agent.get(SHOP_DETAIL_PAGE_URL.gsub('@area_code@', area_code).gsub('@shop_code@', shop_code))
  details = shop_detail_page.search('div.data > ul').children.select{|c|c.element?}
  
  # 電話番号
  result["phone"] = details[0].children.select{|c|c.text?}[0].text

  # 開店時間、閉店時間はフォーマットが店ごとに違いすぎるため綺麗に時刻のみを取得するのが難しい。
  # 文言を設定しておく
  result["open_close"] = details[1].children.select{|c|c.text?}.inject(""){|oc_text, text_node|
    oc_text << (text_node.text)
  }

  # 郵便番号、住所
  result["postal_code"] = details[2].children.select{|c|c.text?}[0].text.scan(/[0-9]{3}-[0-9]{4}/)[0]
  result["address"] = details[2].children.select{|c|c.text?}[1].text  

  # 緯度、経度
  geocoding_xml = mechanize_agent.get(GEOCODING_API_URL.gsub('@address@', result["address"]))

  result["latitude"] = geocoding_xml.search('/result/coordinate/lat').text # 緯度
  result["longitude"] = geocoding_xml.search('/result/coordinate/lng').text # 経度

  result
end

if __FILE__ == $0

  CONFIG = YAML.load(ERB.new(File.open('config.yml').read).result())

  begin
    mechanize_agent = Mechanize.new
    mechanize_agent.verify_mode = OpenSSL::SSL::VERIFY_NONE
    mechanize_agent.user_agent_alias = 'Windows IE 9'
    mechanize_agent.set_proxy(CONFIG['proxy.host'], CONFIG['proxy.port'], CONFIG['proxy.user'], CONFIG['proxy.pass'])

    # p load_shop_detail(mechanize_agent, '03', '894')
    
    save_shop_list(mechanize_agent)

  ensure
    mechanize_agent.shutdown  
  end  
end
